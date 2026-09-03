import Foundation

// Auto-generated from the official HidrateSpark app's connection init to a PRO 2
// (firmware 100.64.0), captured via iPhone HCI sysdiagnose on 2026-09-03. The bottle
// stays in a 15 s idle weight mode and yields no sip records until it has seen this
// sequence. The 0x77 time-of-day frame is regenerated live; everything else is replayed
// verbatim. See docs/PROTOCOL.md.
extension HidrateHandshake {
    /// Full PRO 2 initialisation, in order. Replayed ~50 ms apart.
    public static func pro2(date: Date = Date(), calendar: Calendar = .current) -> [HandshakeStep] {
        // The official app's two cosmetic LED writes (blue-loop 0xb0, red 0x47) are
        // intentionally omitted so the bottle doesn't blink on every connect/reconnect.
        var steps: [HandshakeStep] = []
        steps.append(.init(.config, hex: "6d02", note: ""))
        steps.append(.init(.cmdA1, hex: "07", note: ""))
        steps.append(.init(.setPoint, hex: "933d", note: ""))
        steps.append(.init(.debug, hex: "2201a3", note: ""))
        steps.append(.init(.debug, hex: "21010f", note: ""))
        steps.append(.init(.debug, hex: "b1", note: ""))
        steps.append(.init(.setPoint, hex: "9f", note: ""))
        steps.append(.init(.setPoint, hex: "9c", note: ""))
        steps.append(.init(.debug, hex: "b3", note: ""))
        steps.append(.init(.setPoint, payload: timeOfDayFrame(currentSeconds(date, calendar)), note: "set time of day"))
        steps.append(.init(.setPoint, hex: "a07062000060350100", note: ""))
        steps.append(.init(.setPoint, hex: "00341b00807000000100", note: ""))
        steps.append(.init(.setPoint, hex: "01343700907e00000100", note: ""))
        steps.append(.init(.setPoint, hex: "02345300a08c00000100", note: ""))
        steps.append(.init(.setPoint, hex: "03346f00b09a00000100", note: ""))
        steps.append(.init(.setPoint, hex: "04348b00c0a800000100", note: ""))
        steps.append(.init(.cmdA2, hex: "0809120608011064180212060802106418011208080110641802200512060801106418021206080210641801120808011064180220051206080110641802120608021064180112060801106418021802228601080110021a181005181422002200220022002200220022002200220022001a6610051814220610b60118ae012208080110b30118bc012208080110b10118ca012208080210ae0118d8012208080210ab0118e6012208080310a90118f4012208080210ab0118e8012208080210ad01", note: ""))
        steps.append(.init(.setPoint, hex: "0534a700d0b600000100", note: ""))
        steps.append(.init(.setPoint, hex: "0634c300e0c400000100", note: ""))
        steps.append(.init(.setPoint, hex: "0734df00f0d200000100", note: ""))
        steps.append(.init(.setPoint, hex: "0834fb0000e100000100", note: ""))
        steps.append(.init(.setPoint, hex: "0934170110ef00000100", note: ""))
        steps.append(.init(.setPoint, hex: "0a34330120fd00000100", note: ""))
        steps.append(.init(.setPoint, hex: "0b344f01300b01000100", note: ""))
        steps.append(.init(.setPoint, hex: "0c346b01401901000100", note: ""))
        steps.append(.init(.setPoint, hex: "0d348701502701000100", note: ""))
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
        steps.append(.init(.debug, hex: "40", note: ""))
        steps.append(.init(.cmdA2, hex: "e6012208080310a90118f4012208080210ab0118e8012208080210ad0118dc012208080110af0118d0011a6210051805220610b60118ac01220610b90118a101220610b60118ae012208080110b30118bc012208080110b10118ca012208080210ae0118d8012208080210ab0118e6012208080310a90118f4012208080210ab0118e8012208080210ad0118dc011a6010051805220610b40118b801220610b60118ac01220610b90118a101220610b60118ae012208080110b30118bc0122080801", note: ""))
        steps.append(.init(.cmdA2, hex: "10b10118ca012208080210ae0118d8012208080210ab0118e6012208080310a90118f4012208080210ab0118e8011a60100518052208080110b20118c401220610b40118b801220610b60118ac01220610b90118a101220610b60118ae012208080110b30118bc012208080110b10118ca012208080210ae0118d8012208080210ab0118e6012208080310a90118f4011a60100518052208080110af0118d0012208080110b20118c401220610b40118b801220610b60118ac01220610b90118a101", note: ""))
        steps.append(.init(.cmdA2, hex: "220610b60118ae012208080110b30118bc012208080110b10118ca012208080210ae0118d8012208080210ab0118e6011a60100518052208080210ad0118dc012208080110af0118d0012208080110b20118c401220610b40118b801220610b60118ac01220610b90118a101220610b60118ae012208080110b30118bc012208080110b10118ca012208080210ae0118d8011a60100518052208080210ab0118e8012208080210ad0118dc012208080110af0118d0012208080110b20118c4012206", note: ""))
        steps.append(.init(.cmdA2, hex: "10b40118b801220610b60118ac01220610b90118a101220610b60118ae012208080110b30118bc012208080110b10118ca011a60100518052208080310a90118f4012208080210ab0118e8012208080210ad0118dc012208080110af0118d0012208080110b20118c401220610b40118b801220610b60118ac01220610b90118a101220610b60118ae012208080110b30118bc011a60100518052208080210ab0118e6012208080310a90118f4012208080210ab0118e8012208080210ad0118dc01", note: ""))
        steps.append(.init(.cmdA2, hex: "2208080110af0118d0012208080110b20118c401220610b40118b801220610b60118ac01220610b90118a101220610b60118ae011a62100518052208080210ae0118d8012208080210ab0118e6012208080310a90118f4012208080210ab0118e8012208080210ad0118dc012208080110af0118d0012208080110b20118c401220610b40118b801220610b60118ac01220610b90118a101", note: ""))
        steps.append(.init(.setPoint, hex: "933d", note: ""))
        steps.append(.init(.debug, hex: "2201a3", note: ""))
        steps.append(.init(.debug, hex: "21010f", note: ""))
        steps.append(.init(.setPoint, hex: "a07062000060350100", note: ""))
        steps.append(.init(.debug, hex: "41", note: ""))
        return steps
    }

    static func currentSeconds(_ date: Date, _ calendar: Calendar) -> UInt32 {
        let start = calendar.startOfDay(for: date)
        return UInt32(max(0, min(86_399, date.timeIntervalSince(start))))
    }
}
