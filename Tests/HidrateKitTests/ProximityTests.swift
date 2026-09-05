import Foundation
import Testing
@testable import HidrateKit

@Suite("Picking the closest bottle")
struct ProximityTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Hear a bottle steadily enough that the smoothing has settled on the value.
    private func settle(_ selector: inout ProximitySelector, _ id: String, rssi: Int, at date: Date) {
        for i in 0..<12 { selector.heard(id, rssi: rssi, at: date.addingTimeInterval(Double(i) * 0.1)) }
    }

    @Test func theOnlyBottleHeardWins() {
        var selector = ProximitySelector()
        selector.heard("a", rssi: -70, at: start)
        #expect(selector.choose(from: ["a", "b"], now: start) == "a")
    }

    @Test func nothingHeardKeepsWhateverIsInUse() {
        var selector = ProximitySelector()
        selector.heard("a", rssi: -70, at: start)
        #expect(selector.choose(from: ["a", "b"], now: start) == "a")
        // A bottle in a bag is still the bottle you are using.
        let later = start.addingTimeInterval(600)
        #expect(selector.choose(from: ["a", "b"], now: later) == "a")
    }

    @Test func twoBottlesTheSameDistanceAwayNeverTrade() {
        var selector = ProximitySelector()
        var now = start
        settle(&selector, "a", rssi: -60, at: now)
        settle(&selector, "b", rssi: -62, at: now)
        #expect(selector.choose(from: ["a", "b"], now: now) == "a")

        // An hour of the two swapping places by a few dB, which is what sitting on the
        // same desk looks like. Nothing should move.
        for step in 0..<120 {
            now = start.addingTimeInterval(Double(step) * 30)
            selector.heard("a", rssi: step.isMultiple(of: 2) ? -58 : -64, at: now)
            selector.heard("b", rssi: step.isMultiple(of: 2) ? -63 : -59, at: now)
            #expect(selector.choose(from: ["a", "b"], now: now) == "a")
        }
    }

    @Test func aBottleYouPickUpTakesOver() {
        var selector = ProximitySelector()
        var now = start
        settle(&selector, "a", rssi: -80, at: now)
        settle(&selector, "b", rssi: -82, at: now)
        #expect(selector.choose(from: ["a", "b"], now: now) == "a")

        // Past the shortest turn, then b comes decisively closer and stays there.
        var switched: Date?
        for step in 1...20 {
            now = start.addingTimeInterval(Double(step) * 15)
            selector.heard("a", rssi: -80, at: now)
            selector.heard("b", rssi: -45, at: now)
            if selector.choose(from: ["a", "b"], now: now) == "b", switched == nil { switched = now }
        }
        let handover = try! #require(switched)
        // It waits out the turn the bottle in possession is owed, and no longer.
        #expect(handover.timeIntervalSince(start) >= 120)
        #expect(handover.timeIntervalSince(start) <= 180)
    }

    @Test func aBriefWalkPastDoesNotSteal() {
        var selector = ProximitySelector()
        var now = start.addingTimeInterval(600)  // well past any minimum turn
        settle(&selector, "a", rssi: -70, at: start)
        settle(&selector, "b", rssi: -75, at: start)
        _ = selector.choose(from: ["a", "b"], now: start)

        // b is much closer, but only for fifteen seconds.
        for step in 0..<2 {
            now = start.addingTimeInterval(600 + Double(step) * 8)
            selector.heard("a", rssi: -70, at: now)
            selector.heard("b", rssi: -40, at: now)
            #expect(selector.choose(from: ["a", "b"], now: now) == "a")
        }
        // …and then it is gone again.
        now = start.addingTimeInterval(700)
        settle(&selector, "a", rssi: -70, at: now)
        settle(&selector, "b", rssi: -78, at: now)
        #expect(selector.choose(from: ["a", "b"], now: now) == "a")
    }

    @Test func aBottleGoneQuietHandsOverAtOnce() {
        var selector = ProximitySelector()
        settle(&selector, "a", rssi: -50, at: start)
        #expect(selector.choose(from: ["a", "b"], now: start) == "a")

        // a hasn't been heard in an age; b is right here. No margin, no waiting.
        let later = start.addingTimeInterval(400)
        settle(&selector, "b", rssi: -85, at: later)
        #expect(selector.choose(from: ["a", "b"], now: later) == "b")
    }

    @Test func pinningGivesTheChosenBottleAFullTurn() {
        var selector = ProximitySelector()
        var now = start
        settle(&selector, "a", rssi: -40, at: now)
        settle(&selector, "b", rssi: -85, at: now)
        #expect(selector.choose(from: ["a", "b"], now: now) == "a")

        // Chosen by hand, against what the radio says.
        selector.pin("b", at: now)
        for step in 1...6 {
            now = start.addingTimeInterval(Double(step) * 15)
            selector.heard("a", rssi: -40, at: now)
            selector.heard("b", rssi: -85, at: now)
            #expect(selector.choose(from: ["a", "b"], now: now) == "b")
        }
        // The radio wins again once b has had its turn.
        now = start.addingTimeInterval(300)
        selector.heard("a", rssi: -40, at: now)
        selector.heard("b", rssi: -85, at: now)
        #expect(selector.choose(from: ["a", "b"], now: now) == "a")
    }

    @Test func removingABottleDropsIt() {
        var selector = ProximitySelector()
        settle(&selector, "a", rssi: -50, at: start)
        settle(&selector, "b", rssi: -70, at: start)
        #expect(selector.choose(from: ["a", "b"], now: start) == "a")
        selector.forget("a")
        #expect(selector.choose(from: ["b"], now: start) == "b")
        #expect(selector.strength(of: "a", now: start) == nil)
    }
}

@Suite("Bottle roster")
struct BottleRosterTests {
    @Test func theFirstBottleKeepsItsOldKeys() {
        // Carried over from the single-bottle app, so its calibration has to keep reading
        // the keys it was written under.
        let migrated = SavedBottle(name: "h2oDB618BB", storeKeyPrefix: "HidrateKit")
        #expect(migrated.store(defaults: .standard).keyPrefix == "HidrateKit")
        let fresh = SavedBottle(name: "h2oDB618BB")
        #expect(fresh.storeKeyPrefix == "HidrateKit.bottle.h2oDB618BB")
    }

    @Test func addingTheSameBottleTwiceIsOneBottle() {
        var roster = BottleRoster()
        roster.add(SavedBottle(name: "h2oAAA", nickname: "Desk"))
        roster.add(SavedBottle(name: "h2oAAA"))
        #expect(roster.bottles.count == 1)
        #expect(roster.bottles[0].nickname == "Desk")
    }

    @Test func removingTheActiveBottleClearsIt() {
        var roster = BottleRoster(bottles: [SavedBottle(name: "h2oAAA")], activeID: "h2oAAA")
        let defaults = UserDefaults(suiteName: "roster-test-\(UUID().uuidString)")!
        roster.remove(id: "h2oAAA", defaults: defaults)
        #expect(roster.bottles.isEmpty)
        #expect(roster.activeID == nil)
    }

    @Test func aNicknameStandsInForTheAdvertisedName() {
        var bottle = SavedBottle(name: "h2oDB618BB")
        #expect(bottle.displayName == "h2oDB618BB")
        bottle.nickname = "Gym"
        #expect(bottle.displayName == "Gym")
    }
}
