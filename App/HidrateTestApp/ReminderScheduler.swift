import Foundation
import UserNotifications

/// Local-notification drink reminders on a daily window at a fixed interval.
struct ReminderSettings: Codable, Equatable {
    var enabled = false
    /// Minutes after midnight.
    var startMinutes = 8 * 60
    var endMinutes = 21 * 60
    var intervalMinutes = 90

    var startDate: Date { Self.date(minutes: startMinutes) }
    var endDate: Date { Self.date(minutes: endMinutes) }

    static func date(minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }
    static func minutes(of date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// The daily fire times, as minutes after midnight.
    var fireTimes: [Int] {
        guard enabled, intervalMinutes >= 15, endMinutes > startMinutes else { return [] }
        return stride(from: startMinutes, through: endMinutes, by: intervalMinutes).map { $0 }
    }

    /// The actual moments the next `days` days' reminders would fire, in order.
    func fireDates(within days: Int, from now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        let times = fireTimes
        guard !times.isEmpty else { return [] }
        return (0..<days).flatMap { offset -> [Date] in
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { return [] }
            return times.compactMap { calendar.date(byAdding: .minute, value: $0, to: day) }
        }
        .filter { $0 > now }
    }

    /// How far through the drinking window `date` is: 0 before it opens, 1 once closed.
    func paceFraction(at date: Date = Date(), calendar: Calendar = .current) -> Double {
        guard endMinutes > startMinutes else { return 0 }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return min(max(Double(minutes - startMinutes) / Double(endMinutes - startMinutes), 0), 1)
    }

    /// How much of the goal you should have drunk by `date`, spreading it evenly across
    /// the window. Used to leave out the reminders you're already ahead of.
    func expectedML(by date: Date, goalML: Double, calendar: Calendar = .current) -> Double {
        goalML * paceFraction(at: date, calendar: calendar)
    }
}

@MainActor
enum ReminderScheduler {
    static let identifierPrefix = "hidrate.reminder."

    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        @unknown default: return false
        }
    }

    /// Replaces all scheduled reminders.
    ///
    /// Only the ones you're behind for: a reminder is dropped if today's total already
    /// covers where the goal says you should be by the time it would fire. Because that
    /// depends on how much you've drunk, the reminders are scheduled as individual dates
    /// rather than a repeating daily trigger, and re-laid every time the total moves.
    /// Two days are laid down at a time so the reminders survive a day the app never runs.
    static func apply(_ settings: ReminderSettings, goalML: Double, totalML: Double, now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard settings.enabled else { return }

        let messages = [
            "Time for a sip 💧", "A little water goes a long way.", "Hydration check: take a drink.",
            "Your bottle misses you.", "Sip, then carry on.",
        ]
        let calendar = Calendar.current
        for (index, date) in settings.fireDates(within: 2, from: now).enumerated() {
            // Tomorrow's are unconditional — there is no telling yet how the day will go.
            if calendar.isDateInToday(date), totalML >= settings.expectedML(by: date, goalML: goalML) { continue }
            let content = UNMutableNotificationContent()
            content.title = "Drink some water"
            content.body = messages[index % messages.count]
            content.sound = .default
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let identifier = identifierPrefix + String(Int(date.timeIntervalSince1970))
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        }
    }
}
