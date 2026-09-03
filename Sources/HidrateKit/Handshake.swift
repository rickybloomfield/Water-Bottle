import Foundation

/// Where a handshake write goes.
public enum HandshakeTarget: String, Sendable {
    case debug
    case setPoint
}

/// One write in the connection handshake.
public struct HandshakeStep: Sendable, Hashable {
    public let target: HandshakeTarget
    public let payload: Data
    public let note: String

    public init(_ target: HandshakeTarget, hex: String, note: String) {
        self.target = target
        self.payload = Data(hex: hex) ?? Data()
        self.note = note
    }

    public init(_ target: HandshakeTarget, payload: Data, note: String) {
        self.target = target
        self.payload = payload
        self.note = note
    }
}

/// The write sequence the official app performs right after connecting. The bottle
/// stays silent on its data characteristics until it has seen it.
///
/// The bytes were captured once from the official app (btsnoop) and have been replayed
/// verbatim by every community client since. Decoding them (see `docs/PROTOCOL.md`):
///
/// * `0x77` on Set Point carries the time of day in seconds since midnight as a
///   little-endian u32 at bytes 4..7. The capture holds 55090 s = 15:18:10.
/// * `0x34` frames are glow-reminder slots: byte 0 slot index, bytes 2..3 cumulative
///   target (little-endian u16), bytes 4..7 time of day. The capture's eight slots run
///   08:40 to 20:20 at 100 minute spacing with targets 27.5, 55, ... 220 (slot 1 is
///   missing from the original capture; the bottle does not seem to mind).
/// * `0x92` on Set Point and the two Debug writes are not understood yet.
public enum HidrateHandshake {
    /// Spacing between writes. The official app waits about this long.
    public static let interStepDelay: Duration = .milliseconds(50)

    /// Byte-exact replay of the captured sequence. Proven on Spark 3 and PRO firmware.
    public static let capturedReplay: [HandshakeStep] = [
        HandshakeStep(.debug, hex: "2100d1", note: "debug 0x21 (unknown)"),
        HandshakeStep(.setPoint, hex: "92", note: "set point 0x92 (goal glow?)"),
        HandshakeStep(.debug, hex: "2200f7", note: "debug 0x22 (unknown)"),
        HandshakeStep(.setPoint, hex: "7700000032d70000", note: "set time of day = 15:18:10"),
        HandshakeStep(.setPoint, hex: "00341b00e0790000", note: "reminder slot 0: 27 @ 08:40"),
        HandshakeStep(.setPoint, hex: "02345200c0a80000", note: "reminder slot 2: 82 @ 12:00"),
        HandshakeStep(.setPoint, hex: "03346e0030c00000", note: "reminder slot 3: 110 @ 13:40"),
        HandshakeStep(.setPoint, hex: "04348900a0d70000", note: "reminder slot 4: 137 @ 15:20"),
        HandshakeStep(.setPoint, hex: "0534a50010ef0000", note: "reminder slot 5: 165 @ 17:00"),
        HandshakeStep(.setPoint, hex: "0634c00080060100", note: "reminder slot 6: 192 @ 18:40"),
        HandshakeStep(.setPoint, hex: "0734dc00f01d0100", note: "reminder slot 7: 220 @ 20:20"),
        HandshakeStep(.setPoint, hex: "0834000000000000", note: "reminder slot 8: unused"),
        HandshakeStep(.setPoint, hex: "0934000000000000", note: "reminder slot 9: unused"),
    ]

    /// A glow-reminder slot for the computed handshake.
    public struct ReminderSlot: Sendable, Hashable {
        public var index: UInt8
        public var target: UInt16
        public var secondsSinceMidnight: UInt32

        public init(index: UInt8, target: UInt16, secondsSinceMidnight: UInt32) {
            self.index = index
            self.target = target
            self.secondsSinceMidnight = secondsSinceMidnight
        }
    }

    /// Same sequence, but with the real time of day and a caller-supplied reminder
    /// schedule (empty by default, which clears all ten slots). This is the decoded
    /// hypothesis; it has not been verified against the bottle as thoroughly as the
    /// replay, so `HidrateBottleClient` keeps replay as the default.
    public static func computed(
        date: Date = Date(),
        calendar: Calendar = .current,
        reminders: [ReminderSlot] = []
    ) -> [HandshakeStep] {
        let startOfDay = calendar.startOfDay(for: date)
        let seconds = UInt32(max(0, min(86_399, date.timeIntervalSince(startOfDay))))

        var steps: [HandshakeStep] = [
            HandshakeStep(.debug, hex: "2100d1", note: "debug 0x21 (unknown)"),
            HandshakeStep(.setPoint, hex: "92", note: "set point 0x92 (goal glow?)"),
            HandshakeStep(.debug, hex: "2200f7", note: "debug 0x22 (unknown)"),
            HandshakeStep(.setPoint, payload: timeOfDayFrame(seconds), note: "set time of day = \(seconds) s"),
        ]
        let byIndex = Dictionary(reminders.map { ($0.index, $0) }, uniquingKeysWith: { _, last in last })
        for index in UInt8(0)...9 {
            let slot = byIndex[index] ?? ReminderSlot(index: index, target: 0, secondsSinceMidnight: 0)
            steps.append(HandshakeStep(.setPoint, payload: reminderFrame(slot), note: "reminder slot \(index)"))
        }
        return steps
    }

    /// Eight evenly spaced reminder slots between two times of day, targets rising to `goal`.
    public static func evenlySpacedReminders(
        from startSeconds: UInt32, to endSeconds: UInt32, goal: UInt16, count: Int = 8
    ) -> [ReminderSlot] {
        guard count > 0, endSeconds > startSeconds else { return [] }
        return (0..<count).map { i in
            let fraction = Double(i + 1) / Double(count)
            let time = Double(startSeconds) + Double(endSeconds - startSeconds) * Double(i) / Double(max(1, count - 1))
            return ReminderSlot(
                index: UInt8(i),
                target: UInt16((Double(goal) * fraction).rounded()),
                secondsSinceMidnight: UInt32(time.rounded())
            )
        }
    }

    static func timeOfDayFrame(_ seconds: UInt32) -> Data {
        var data = Data([0x77, 0x00, 0x00, 0x00])
        data.append(littleEndian(seconds))
        return data
    }

    static func reminderFrame(_ slot: ReminderSlot) -> Data {
        var data = Data([slot.index, 0x34])
        data.append(littleEndian(slot.target))
        data.append(littleEndian(slot.secondsSinceMidnight))
        return data
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
