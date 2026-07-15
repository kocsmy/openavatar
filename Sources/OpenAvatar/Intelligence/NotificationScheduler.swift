import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Schedules the local notifications that resurface a follow-up at its due time.
/// Uses the system notification center, so a scheduled reminder fires even if
/// the app has been quit since. No-ops on platforms without UserNotifications.
enum NotificationScheduler {

    /// Ask for permission to post alerts. Safe to call repeatedly.
    @discardableResult
    static func requestAuthorization() async -> Bool {
#if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
#else
        return false
#endif
    }

    /// Schedule (or reschedule) the reminder for a follow-up. Keyed on the
    /// follow-up id, so calling again replaces any prior schedule.
    static func schedule(_ followUp: FollowUp) {
#if canImport(UserNotifications)
        guard followUp.dueAt > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Follow-up from your call"
        content.body = followUp.title
        content.sound = .default

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: followUp.dueAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(
            identifier: followUp.id.uuidString, content: content, trigger: trigger)

        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [followUp.id.uuidString])
        center.add(request)
#endif
    }

    static func cancel(id: UUID) {
#if canImport(UserNotifications)
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id.uuidString])
#endif
    }
}
