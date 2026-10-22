import AppKit
import HedwigCore
import UserNotifications

/// Until Patronus sends tickets and deadlines to Telegram, the Mac reminds:
/// at nine on the day of an outing, and four weeks and a week before a
/// deadline. Rescheduled whenever the outings change.
@MainActor
final class OutingNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let model: AppModel
    private static let askedKey = "hedwig.outings.askedForNotifications"

    init(model: AppModel) {
        self.model = model
    }

    // Without a bundle (`swift run`) the notification center crashes the process.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func start() {
        center?.delegate = self
        model.outingsChanged = { [weak self] in self?.schedule() }
        schedule()
    }

    func schedule() {
        guard let center else { return }
        let reminders = model.outingReminders()
        Task {
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("outing.") }
            center.removePendingNotificationRequests(withIdentifiers: pending)
            guard !reminders.isEmpty, await allowed(center) else { return }
            for reminder in reminders {
                let content = UNMutableNotificationContent()
                content.title = reminder.title
                content.body = reminder.body
                content.userInfo = ["outingId": reminder.outingId]
                let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireAt)
                let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
            }
        }
    }

    /// Asks once, and only when there is something to remind of.
    private func allowed(_ center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined:
            guard !UserDefaults.standard.bool(forKey: Self.askedKey) else { return false }
            UserDefaults.standard.set(true, forKey: Self.askedKey)
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let id = response.notification.request.content.userInfo["outingId"] as? String else { return }
        await MainActor.run {
            NSApp.activate()
            model.showOuting(id)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
