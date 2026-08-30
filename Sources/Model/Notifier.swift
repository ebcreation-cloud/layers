import Foundation
import UserNotifications

/// Alerts 30 minutes and 5 minutes before an event, and at its start.
///
/// The app schedules local notifications rather than writing EKAlarms onto the events.
/// Writing alarms would change the originals and propagate to every other device.
/// Local notifications leave the data alone and can carry the video-call link in the
/// body and in an action button.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()
    private let category = "LAYERS_EVENT"
    /// The system caps how many pending notifications it keeps, so fill from the soonest.
    private let maxPending = 60
    private let offsets = Config.alertOffsets

    func start() {
        center.delegate = self
        let join = UNNotificationAction(identifier: "JOIN", title: "Join", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [join],
                                   intentIdentifiers: [], options: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func schedule(_ items: [Item]) {
        center.removeAllPendingNotificationRequests()
        let now = Date()
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        let upcoming = items
            .filter { !$0.isAllDay && $0.start > now && $0.start < horizon }
            .sorted { $0.start < $1.start }

        var made = 0
        for item in upcoming {
            for m in offsets {
                guard made < maxPending else { return }
                let fire = item.start.addingTimeInterval(TimeInterval(-m * 60))
                guard fire > now else { continue }

                let c = UNMutableNotificationContent()
                c.title = item.title
                c.subtitle = m == 0 ? "Starting now" : "in \(m) min · \(Fmt.hm(item.start))"
                if let meet = item.meetURL {
                    c.body = meet.host ?? meet.absoluteString
                    c.userInfo = ["url": meet.absoluteString]
                    c.categoryIdentifier = category      // attaches the Join button
                } else if !item.location.isEmpty {
                    c.body = item.location
                }
                c.sound = m == 0 ? .default : nil

                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let req = UNNotificationRequest(
                    identifier: "\(item.ekID)-\(m)",
                    content: c,
                    trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
                center.add(req)
                made += 1
            }
        }
    }

    /// Show alerts even when the app is frontmost. Five minutes before a call you need
    /// to know regardless of what you are looking at.
    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Tapping the alert or its Join button opens the meeting link.
    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                didReceive r: UNNotificationResponse) async {
        guard let s = r.notification.request.content.userInfo["url"] as? String,
              let url = URL(string: s) else { return }
        await MainActor.run { openExternal(url) }
    }
}
