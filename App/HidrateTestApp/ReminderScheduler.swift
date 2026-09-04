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

    /// Replaces all scheduled reminders with the given settings.
    static func apply(_ settings: ReminderSettings, unit: VolumeUnit, goalML: Double) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard settings.enabled else { return }

        let messages = [
            "Time for a sip 💧", "A little water goes a long way.", "Hydration check: take a drink.",
            "Your bottle misses you.", "Sip, then carry on.",
        ]
        for (index, minutes) in settings.fireTimes.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = "Drink some water"
            content.body = messages[index % messages.count]
            content.sound = .default
            var components = DateComponents()
            components.hour = minutes / 60
            components.minute = minutes % 60
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let request = UNNotificationRequest(identifier: identifierPrefix + String(minutes), content: content, trigger: trigger)
            try? await center.add(request)
        }
    }
}
