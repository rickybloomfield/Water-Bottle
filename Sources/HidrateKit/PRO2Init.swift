import Foundation

// Auto-generated from the official HidrateSpark app's connection init to a PRO 2
// (firmware 100.64.0), captured via iPhone HCI sysdiagnose on 2026-09-03. The bottle
// stays in a 15 s idle weight mode and yields no sip records until it has seen this
// sequence. The 0x77 time-of-day frame is regenerated live; everything else is replayed
// verbatim. See docs/PROTOCOL.md.
/// The parts of the PRO 2 init that can be left out. Everything else in it is sent as
/// captured.
public enum PRO2InitPart: String, CaseIterable, Sendable, Codable {
    /// Slots `00`–`0d`: the hourly glow-reminder schedule, 08:00 to 21:00, with
    /// cumulative targets rising to the day's goal. Omitted, they are written cleared.
    case reminderSlots
    /// Set Point `93 3d`, sent at the start and the end — "SetGoalGlow" in the decompiled
    /// app, argument unknown.
    case goalGlow
    /// Set Point `a0`: the reminder window, 07:00 to 22:00.
    case window
    /// The protobuf goal-and-schedule blob written to the command-A data channel in
    /// five parts, captured from the official app on 3 September.
    case goalBlob
    /// The 49 slot-table frames themselves, `00`–`30`, whether carrying the schedule or
    /// cleared.
    case slotTable
    /// The Debug-characteristic commands still sent: `2201a3`, `21010f`, `b1`, `b3`.
    /// Leaving the first two out once silenced the bottle for a minute and once didn't;
    /// `b1` and `b3` do nothing anyone has noticed. All four are kept as captured.
    case debugCommands
    /// Set Point `9f` and `9c`, opcodes of unknown meaning.
    case setPoint9f9c
    /// Set Point `77`: the time of day, regenerated live.
    case timeOfDay
    /// The capacity write (`6d02`, twice) and the `07` to command-A control.
    case capacityAndControl
    /// The debug commands one by one: `22 01 a3` and `21 01 0f` (each sent twice, at the
    /// start and the end), `b1`, `b3`.
    case debug22, debug21, debugB1, debugB3

    public var title: String {
        switch self {
        case .reminderSlots: "Hourly reminder schedule"
        case .goalGlow: "Goal glow (93 3d)"
        case .window: "Reminder window (a0)"
        case .goalBlob: "Goal and schedule blob"
        case .slotTable: "Slot table frames"
        case .debugCommands: "Debug commands"
        case .setPoint9f9c: "Set point 9f and 9c"
        case .timeOfDay: "Time of day (77)"
        case .capacityAndControl: "Capacity and control (6d02, 07)"
        case .debug22: "Debug 22 01 a3"
        case .debug21: "Debug 21 01 0f"
        case .debugB1: "Debug b1"
        case .debugB3: "Debug b3"
        }
    }
}

extension HidrateHandshake {
    /// Full PRO 2 initialisation, in order. Replayed ~50 ms apart.
    ///
    /// Parts of it can be left out. That is how the red flash the bottle played some
    /// seconds after every connect was run down to Debug `41` (and a blue one to `40`),
    /// and the machinery stays for the next such hunt. With the reminder slots omitted
    /// they are written cleared, like the ones after them; the other parts are simply
    /// not sent.
    public static func pro2(date: Date = Date(), calendar: Calendar = .current,
                            omitting omitted: Set<PRO2InitPart> = [.reminderSlots]) -> [HandshakeStep] {
        // The official app's two cosmetic LED writes (blue-loop 0xb0, red 0x47) are
        // intentionally omitted so the bottle doesn't blink on every connect/reconnect.
        // So are its Debug commands `40` and `41`, found by bisection on 7 September.
        // They start the firmware's own after-connect routine, which arrives all at once
        // anywhere from a second to a minute after the init: a blue flash (`40`), the red
        // pattern (`41`), each announced on the light-activity characteristic as it
        // plays, and about fifty seconds of weight reports every 2 s instead of every 15.
        // Without them the bottle stays dark and simply reports every 15 s from the
        // start, as it does for the rest of every session anyway; the first settled
        // reading arrives just as soon either way, around fifteen seconds in. Reading the
        // weight characteristic returns `00` on this firmware, so there is no quieter way
        // to the fast spell, and nothing here depends on it.
        func slot(_ hex: String) -> HandshakeStep {
            .init(.setPoint, hex: omitted.contains(.reminderSlots) ? String(hex.prefix(2)) + "000000000000000000" : hex, note: "")
        }
        var steps: [HandshakeStep] = []
        steps.append(.init(.config, hex: "6d02", note: ""))
        steps.append(.init(.cmdA1, hex: "07", note: ""))
        if !omitted.contains(.goalGlow) { steps.append(.init(.setPoint, hex: "933d", note: "")) }
        steps.append(.init(.debug, hex: "2201a3", note: ""))
        steps.append(.init(.debug, hex: "21010f", note: ""))
        steps.append(.init(.debug, hex: "b1", note: ""))
        steps.append(.init(.setPoint, hex: "9f", note: ""))
        steps.append(.init(.setPoint, hex: "9c", note: ""))
        steps.append(.init(.debug, hex: "b3", note: ""))
        steps.append(.init(.setPoint, payload: timeOfDayFrame(currentSeconds(date, calendar)), note: "set time of day"))
        if !omitted.contains(.window) { steps.append(.init(.setPoint, hex: "a07062000060350100", note: "")) }
        steps.append(slot("00341b00807000000100"))
        steps.append(slot("01343700907e00000100"))
        steps.append(slot("02345300a08c00000100"))
        steps.append(slot("03346f00b09a00000100"))
        steps.append(slot("04348b00c0a800000100"))
        steps.append(.init(.cmdA2, hex: "0809120608011064180212060802106418011208080110641802200512060801106418021206080210641801120808011064180220051206080110641802120608021064180112060801106418021802228601080110021a181005181422002200220022002200220022002200220022001a6610051814220610b60118ae012208080110b30118bc012208080110b10118ca012208080210ae0118d8012208080210ab0118e6012208080310a90118f4012208080210ab0118e8012208080210ad01", note: ""))
        steps.append(slot("0534a700d0b600000100"))
        steps.append(slot("0634c300e0c400000100"))
        steps.append(slot("0734df00f0d200000100"))
        steps.append(slot("0834fb0000e100000100"))
        steps.append(slot("0934170110ef00000100"))
        steps.append(slot("0a34330120fd00000100"))
        steps.append(slot("0b344f01300b01000100"))
        steps.append(slot("0c346b01401901000100"))
        steps.append(slot("0d348701502701000100"))
        steps.append(.init(.setPoint, hex: "0e000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "0f000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "10000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "11000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "12000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "13000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "14000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "15000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "16000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "17000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "18000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "19000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "1a000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "1b000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "1c000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "1d000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "1e000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "1f000000000000000000", note: ""))
        steps.append(.init(.cmdA2, hex: "18dc012208080110af0118d0012208080110b20118c40122c8080802100b1a6610051805220610b60118ae012208080110b30118bc012208080110b10118ca012208080210ae0118d8012208080210ab0118e6012208080310a90118f4012208080210ab0118e8012208080210ad0118dc012208080110af0118d0012208080110b20118c4011a6410051805220610b90118a101220610b60118ae012208080110b30118bc012208080110b10118ca012208080210ae0118d8012208080210ab0118", note: ""))
        steps.append(.init(.setPoint, hex: "20000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "21000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "22000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "23000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "24000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "25000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "26000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "27000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "28000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "29000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "2a000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "2b000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "2c000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "2d000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "2e000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "2f000000000000000000", note: ""))
        steps.append(.init(.setPoint, hex: "30000000000000000000", note: ""))
        steps.append(.init(.config, hex: "6d02", note: ""))
        steps.append(.init(.cmdA2, hex: "e6012208080310a90118f4012208080210ab0118e8012208080210ad0118dc012208080110af0118d0011a6210051805220610b60118ac01220610b90118a101220610b60118ae012208080110b30118bc012208080110b10118ca012208080210ae0118d8012208080210ab0118e6012208080310a90118f4012208080210ab0118e8012208080210ad0118dc011a6010051805220610b40118b801220610b60118ac01220610b90118a101220610b60118ae012208080110b30118bc0122080801", note: ""))
        steps.append(.init(.cmdA2, hex: "10b10118ca012208080210ae0118d8012208080210ab0118e6012208080310a90118f4012208080210ab0118e8011a60100518052208080110b20118c401220610b40118b801220610b60118ac01220610b90118a101220610b60118ae012208080110b30118bc012208080110b10118ca012208080210ae0118d8012208080210ab0118e6012208080310a90118f4011a60100518052208080110af0118d0012208080110b20118c401220610b40118b801220610b60118ac01220610b90118a101", note: ""))
        steps.append(.init(.cmdA2, hex: "220610b60118ae012208080110b30118bc012208080110b10118ca012208080210ae0118d8012208080210ab0118e6011a60100518052208080210ad0118dc012208080110af0118d0012208080110b20118c401220610b40118b801220610b60118ac01220610b90118a101220610b60118ae012208080110b30118bc012208080110b10118ca012208080210ae0118d8011a60100518052208080210ab0118e8012208080210ad0118dc012208080110af0118d0012208080110b20118c4012206", note: ""))
        steps.append(.init(.cmdA2, hex: "10b40118b801220610b60118ac01220610b90118a101220610b60118ae012208080110b30118bc012208080110b10118ca011a60100518052208080310a90118f4012208080210ab0118e8012208080210ad0118dc012208080110af0118d0012208080110b20118c401220610b40118b801220610b60118ac01220610b90118a101220610b60118ae012208080110b30118bc011a60100518052208080210ab0118e6012208080310a90118f4012208080210ab0118e8012208080210ad0118dc01", note: ""))
        steps.append(.init(.cmdA2, hex: "2208080110af0118d0012208080110b20118c401220610b40118b801220610b60118ac01220610b90118a101220610b60118ae011a62100518052208080210ae0118d8012208080210ab0118e6012208080310a90118f4012208080210ab0118e8012208080210ad0118dc012208080110af0118d0012208080110b20118c401220610b40118b801220610b60118ac01220610b90118a101", note: ""))
        if !omitted.contains(.goalGlow) { steps.append(.init(.setPoint, hex: "933d", note: "")) }
        steps.append(.init(.debug, hex: "2201a3", note: ""))
        steps.append(.init(.debug, hex: "21010f", note: ""))
        if !omitted.contains(.window) { steps.append(.init(.setPoint, hex: "a07062000060350100", note: "")) }
        if omitted.contains(.goalBlob) { steps.removeAll { $0.target == .cmdA2 } }
        if omitted.contains(.slotTable) { steps.removeAll { $0.target == .setPoint && $0.payload.count == 10 } }
        if omitted.contains(.debugCommands) { steps.removeAll { $0.target == .debug } }
        let single: [(PRO2InitPart, String)] = [(.debug22, "2201a3"), (.debug21, "21010f"), (.debugB1, "b1"), (.debugB3, "b3")]
        for (part, hex) in single where omitted.contains(part) {
            let payload = Data(hex: hex) ?? Data()
            steps.removeAll { $0.target == .debug && $0.payload == payload }
        }
        if omitted.contains(.setPoint9f9c) { steps.removeAll { $0.target == .setPoint && ($0.payload == Data([0x9f]) || $0.payload == Data([0x9c])) } }
        if omitted.contains(.timeOfDay) { steps.removeAll { $0.target == .setPoint && $0.payload.first == 0x77 } }
        if omitted.contains(.capacityAndControl) { steps.removeAll { $0.target == .config || $0.target == .cmdA1 } }
        return steps
    }

    static func currentSeconds(_ date: Date, _ calendar: Calendar) -> UInt32 {
        let start = calendar.startOfDay(for: date)
        return UInt32(max(0, min(86_399, date.timeIntervalSince(start))))
    }
}
