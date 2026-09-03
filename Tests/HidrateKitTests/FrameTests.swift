import Foundation
import Testing
@testable import HidrateKit

@Suite("Sip frames")
struct SipFrameTests {
    // Real frames logged from a HidrateSpark PRO (community corpus).
    static let realFrames = [
        "0119ea000400000075872a8bd789e78800000000",
        "011903010800000075872a8be788f28700000000",
        "01090c010100000075872a8bf2879b8700000000",
        "010d0d000400000075872a8bda8a5a8a00000000",
        "012f45000400000075872a8b018a428800000000",
    ]

    @Test func parsesRealFrame() throws {
        let record = try #require(SipRecord(data: Data(hex: Self.realFrames[0])!))
        #expect(record.pendingCount == 1)
        #expect(record.percentOfCapacity == 25)
        #expect(record.cumulativePercent == 234)
        #expect(record.flags == 4)
        #expect(record.rawWeightBefore == 0x89D7)
        #expect(record.rawWeightAfter == 0x88E7)
        #expect(record.rawWeightDelta == 240)
        #expect(record.hasPayload)
        #expect(!record.isQueueEmptyMarker)
        #expect(record.volumeML(capacityML: 621) == 155.25)
    }

    @Test func consecutiveFramesChainWeights() throws {
        let a = try #require(SipRecord(data: Data(hex: Self.realFrames[1])!))
        let b = try #require(SipRecord(data: Data(hex: Self.realFrames[2])!))
        #expect(a.rawWeightAfter == b.rawWeightBefore)
        #expect(b.cumulativePercent - a.cumulativePercent == b.percentOfCapacity)
    }

    @Test func weightDerivedVolumeUsesCalibration() throws {
        let record = try #require(SipRecord(data: Data(hex: Self.realFrames[0])!))
        let calibration = BottleCalibration(emptyRaw: 35000, fullRaw: 35000 + 1.305 * 621, capacityML: 621)
        let ml = try #require(record.weightDerivedVolumeML(calibration: calibration))
        #expect(abs(ml - 240 / 1.305) < 0.01)
    }

    @Test func rejectsCorruptFullBottleSip() throws {
        let corrupt = try #require(SipRecord(data: Data(hex: "016464000400000075872a8b5687378700000000")!))
        #expect(corrupt.percentOfCapacity == 100)
        #expect(!corrupt.isPlausible(rawUnitsPerML: 1.305, capacityML: 621))
        let good = try #require(SipRecord(data: Data(hex: Self.realFrames[0])!))
        #expect(good.isPlausible(rawUnitsPerML: 1.305, capacityML: 621))
    }

    @Test func recognisesQueueMarkers() throws {
        let empty = try #require(SipRecord(data: Data(repeating: 0, count: 20)))
        #expect(empty.isQueueEmptyMarker)
        #expect(!empty.hasPayload)

        var announcement = Data(repeating: 0, count: 20)
        announcement[0] = 2
        let pending = try #require(SipRecord(data: announcement))
        #expect(pending.pendingCount == 2)
        #expect(!pending.hasPayload)
    }

    @Test func tooShortFrameIsRejected() {
        #expect(SipRecord(data: Data([0x01, 0x02])) == nil)
    }
}

@Suite("Weight and cap frames")
struct SensorFrameTests {
    @Test func weightIsBigEndian() throws {
        let sample = try #require(WeightSample(data: Data([0x8A, 0xC0])))
        #expect(sample.raw == 0x8AC0)
        #expect(sample.highByte == 0x8A)
        #expect(sample.lowByte == 0xC0)
        #expect(WeightSample(data: Data([0x01])) == nil)
    }

    @Test func capStateDecodes() {
        #expect(CapState(data: Data(hex: "81020000")!) == .open)
        #expect(CapState(data: Data(hex: "80020000")!) == .closed)
        #expect(CapState(data: Data(hex: "2100d1")!) == nil)
        #expect(CapState(data: Data()) == nil)
    }

    @Test func hexRoundTrips() {
        let data = Data(hex: "00ff10Ab")
        #expect(data == Data([0x00, 0xFF, 0x10, 0xAB]))
        #expect(data?.hexString == "00ff10ab")
        #expect(Data(hex: "abc") == nil)
        #expect(Data(hex: "zz") == nil)
    }
}

@Suite("Handshake")
struct HandshakeTests {
    @Test func capturedReplayIsIntact() {
        let steps = HidrateHandshake.capturedReplay
        #expect(steps.count == 13)
        #expect(steps[0].target == .debug)
        #expect(steps[0].payload.hexString == "2100d1")
        #expect(steps[3].payload.hexString == "7700000032d70000")
        #expect(steps[12].payload.hexString == "0934000000000000")
    }

    @Test func decodedFramesReproduceTheCapture() {
        #expect(HidrateHandshake.timeOfDayFrame(55090).hexString == "7700000032d70000")
        #expect(HidrateHandshake.reminderFrame(.init(index: 0, target: 27, secondsSinceMidnight: 31200)).hexString == "00341b00e0790000")
        #expect(HidrateHandshake.reminderFrame(.init(index: 7, target: 220, secondsSinceMidnight: 73200)).hexString == "0734dc00f01d0100")
        #expect(HidrateHandshake.reminderFrame(.init(index: 9, target: 0, secondsSinceMidnight: 0)).hexString == "0934000000000000")
    }

    @Test func computedHandshakeUsesRealTimeOfDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 15, minute: 18, second: 10)))
        let steps = HidrateHandshake.computed(date: date, calendar: calendar)
        #expect(steps.count == 14)
        #expect(steps[3].payload.hexString == "7700000032d70000")
        #expect(steps[4].payload.hexString == "0034000000000000")
        #expect(steps.filter { $0.target == .debug }.count == 2)
    }

    @Test func evenlySpacedRemindersMatchCaptureShape() {
        let slots = HidrateHandshake.evenlySpacedReminders(from: 31200, to: 73200, goal: 220)
        #expect(slots.count == 8)
        #expect(slots[0].secondsSinceMidnight == 31200)
        #expect(slots[7].secondsSinceMidnight == 73200)
        #expect(slots[7].target == 220)
        #expect(slots[3].target == 110)
    }
}
