import Foundation

/// The numbers both Today screens are built from. They disagree about how to draw the
/// day, not about what is true of it, so the arithmetic lives here once and each screen
/// only decides what to show.
struct TodayFacts {
    var totalML: Double
    var goalML: Double
    /// How amounts are shown, which decides how close counts as reached.
    var unit: VolumeUnit
    /// Where the day's drinking window says you should be by now.
    var paceTargetML: Double
    /// How far through the window it is, 0…1.
    var paceFraction: Double
    var windowStartMinutes: Int
    var windowEndMinutes: Int
    /// Consecutive days at goal, today included once it's done.
    var streak: Int
    var drinkCount: Int
    /// False when at least one of the day's drinks failed to reach Apple Health, which is
    /// the only case worth saying anything about.
    var allInHealth: Bool

    var progress: Double { reached ? 1 : (goalML > 0 ? min(totalML / goalML, 1) : 0) }
    var overflow: Double { goalML > 0 ? min(max(totalML / goalML - 1, 0), 1) : 0 }
    var reached: Bool { unit.reachedGoal(totalML, goalML: goalML) }
    var remainingML: Double { max(goalML - totalML, 0) }

    /// Positive when ahead of pace, negative when behind. Nil outside the window, and
    /// once the goal is in, because there is no longer a pace to be off.
    var offPaceML: Double? {
        guard !reached, paceFraction > 0, paceFraction < 1 else { return nil }
        return totalML - paceTargetML
    }

    var isAhead: Bool { (offPaceML ?? 0) >= 0 }

    /// Where the window closes, for "26 oz to go by 9 PM".
    var windowEnd: Date { ReminderSettings.date(minutes: windowEndMinutes) }
    var windowStart: Date { ReminderSettings.date(minutes: windowStartMinutes) }

    /// Consecutive days at goal ending today — or yesterday, when today isn't done yet,
    /// so a streak isn't reported broken before the day has had its chance.
    static func streak(in totals: [Date: Double],
                       goalML: Double,
                       todayTotalML: Double,
                       unit: VolumeUnit,
                       calendar: Calendar = .current) -> Int {
        guard goalML > 0 else { return 0 }
        let today = calendar.startOfDay(for: Date())
        var day = today
        if !unit.reachedGoal(totals[day] ?? todayTotalML, goalML: goalML) {
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        var count = 0
        while unit.reachedGoal(totals[day] ?? 0, goalML: goalML) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}
