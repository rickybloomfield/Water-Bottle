import Foundation

/// Everything the widget, the complication and the watch app need to draw today's ring,
/// offer a one-tap drink, and — on the watch — list the day's drinks. The phone app owns
/// it and writes it to the shared app group after every change.
struct HydrationSnapshot: Codable, Hashable, Sendable {
    /// The day `totalML` belongs to, so a widget that wakes up after midnight knows the
    /// number it is holding is yesterday's.
    var day: Date = Calendar.current.startOfDay(for: Date())
    var totalML: Double = 0
    var goalML: Double = 64 * VolumeUnit.mlPerOunce
    var unit: VolumeUnit = .ounces
    var lastDrinkDate: Date?
    /// 0…1, how full the bottle itself is, when we have a live reading.
    var bottleFillFraction: Double?
    var isBottleConnected: Bool = false
    /// Drinks logged from the widget or the watch that the phone has now taken over, and
    /// deletions asked for from the watch that it has dealt with — by the request's own
    /// id — so the sender can stop adjusting for them locally.
    var acknowledgedDrinkIDs: [UUID] = []
    /// Today's drinks, newest first, so the watch can list them and offer to remove one.
    /// Optional so an older stored snapshot still decodes.
    var drinks: [Drink]?
    /// The hours you drink across, from the reminder settings, as minutes after midnight.
    /// Optional so an older stored snapshot still decodes.
    var windowStartMinutes: Int?
    var windowEndMinutes: Int?
    var updated: Date = Date()

    var isStale: Bool { !Calendar.current.isDateInToday(day) }
    var progress: Double { goalReached ? 1 : (goalML > 0 ? min(totalML / goalML, 1) : 0) }
    /// How far round a second lap, once the goal is in. Capped at one more lap: past
    /// twice the goal the ring stops saying anything new.
    var overflow: Double { goalML > 0 ? min(max(totalML / goalML - 1, 0), 1) : 0 }
    var goalReached: Bool { unit.reachedGoal(totalML, goalML: goalML) }
    var remainingML: Double { max(goalML - totalML, 0) }

    // MARK: - Pace

    /// Default window if the snapshot predates the setting, or reminders were never set up.
    static let defaultWindow = (start: 8 * 60, end: 21 * 60)

    var windowStart: Int { windowStartMinutes ?? Self.defaultWindow.start }
    var windowEnd: Int { windowEndMinutes ?? Self.defaultWindow.end }

    /// How far through the drinking window it is: 0 before it opens, 1 once it has closed.
    func paceFraction(at date: Date = Date()) -> Double {
        guard windowEnd > windowStart else { return 0 }
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return min(max(Double(minutes - windowStart) / Double(windowEnd - windowStart), 0), 1)
    }

    /// Where the total ought to be by now to finish the goal by the end of the window.
    func targetML(at date: Date = Date()) -> Double { goalML * paceFraction(at: date) }

    func isOnTrack(at date: Date = Date()) -> Bool { totalML >= targetML(at: date) }

    /// How far behind, or nil when the day is on or ahead of pace.
    func shortfallML(at date: Date = Date()) -> Double? {
        let short = targetML(at: date) - totalML
        return short > 0 ? short : nil
    }

    /// Where the pace marker sits on the ring, or nil when there is nothing useful to
    /// mark: the window hasn't opened, it has closed, or the goal is already in.
    func paceMarker(at date: Date = Date()) -> Double? {
        guard !goalReached else { return nil }
        let fraction = paceFraction(at: date)
        return fraction > 0 && fraction < 1 ? fraction : nil
    }

    /// Everything the widget, the watch and the complication actually draw. Publishing is
    /// gated on this so a no-op refresh doesn't spend a widget reload or a watch push.
    func matchesDisplay(of other: HydrationSnapshot) -> Bool {
        day == other.day
            && totalML == other.totalML
            && goalML == other.goalML
            && unit == other.unit
            && windowStart == other.windowStart
            && windowEnd == other.windowEnd
            && acknowledgedDrinkIDs == other.acknowledgedDrinkIDs
    }

    /// `matchesDisplay`, and the day's list as well: what the watch app shows beyond the
    /// ring. A corrected time, or a drink deleted and logged again, changes this and not
    /// the face — which earns the watch a new context, and the widget no reload.
    func matchesContent(of other: HydrationSnapshot) -> Bool {
        matchesDisplay(of: other) && (drinks ?? []) == (other.drinks ?? [])
    }

    /// `matchesDisplay` as a value, for remembering what a face was last given.
    var displayFingerprint: String {
        "\(Int(day.timeIntervalSince1970))|\(totalML)|\(goalML)|\(unit.rawValue)|\(windowStart)|\(windowEnd)|\(acknowledgedDrinkIDs.count)"
    }

    var presetsML: [Double] { unit.presetsML }

    /// "12 oz to go" / "Goal reached", for the line under a ring.
    var footer: String { goalReached ? "Goal reached" : "\(volume(remainingML)) to go" }

    /// "38 of 64 oz" — the unit once, for the narrow accessory families.
    var totalOfGoal: String { "\(number(totalML)) of \(volume(goalML))" }

    func volume(_ ml: Double) -> String { unit.format(ml) }
    func number(_ ml: Double) -> String { unit.number(ml) }
}

extension HydrationSnapshot {
    /// One of today's drinks as the watch sees it: enough to draw a row and to ask the
    /// phone to remove it, without the watch knowing about entries, samples or Health.
    struct Drink: Codable, Hashable, Sendable, Identifiable {
        enum Origin: String, Codable, Sendable {
            case bottle
            case manual
            case widget
            case watch
            case emptied
            /// Written to Apple Health by another app. The phone reads it and counts it,
            /// and can no more delete it than the watch can.
            case health
        }

        var id: UUID
        var date: Date
        var volumeML: Double
        var origin: Origin
        /// For a Health sample, the app that wrote it.
        var sourceName: String?
        var approximate: Bool = false

        var canDelete: Bool { origin != .health }

        var symbolName: String {
            switch origin {
            case .bottle: "waterbottle.fill"
            case .manual: "hand.tap.fill"
            case .widget: "square.grid.2x2.fill"
            case .watch: "applewatch"
            case .emptied: "waterbottle"
            case .health: "heart.fill"
            }
        }

        /// Where the drink came from, in a word or two: a watch row has no room for more.
        var label: String {
            switch origin {
            case .bottle: "Bottle"
            case .manual: "By hand"
            case .widget: "Widget"
            case .watch: "Watch"
            case .emptied: "Left in bottle"
            case .health: sourceName ?? "Health"
            }
        }
    }
}

/// A drink removed on the watch, waiting for the phone to take it out of its history and
/// out of Apple Health. It has an id of its own, distinct from the drink's, and that is
/// what the phone acknowledges: the drink's id may already be acknowledged from when the
/// drink was adopted, which would have the watch treat the deletion as done at once.
struct DrinkDeletion: Codable, Hashable, Sendable, Identifiable {
    var id: UUID = UUID()
    var drinkID: UUID
    var date: Date = Date()
}

/// A drink logged from the widget or the watch, waiting for the phone app to adopt it
/// (write it to Health, put it in the history). Until then it still counts toward the
/// displayed total, so a tap shows up immediately.
struct PendingDrink: Codable, Hashable, Sendable, Identifiable {
    enum Origin: String, Codable, Sendable {
        case widget
        case watch
    }

    var id: UUID = UUID()
    var date: Date = Date()
    var volumeML: Double
    var origin: Origin
}
