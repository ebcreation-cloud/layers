import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#endif

/// One alert about to be raised: an event, and how long before it starts.
struct EventAlert {
    let id: String          // matches the system request's identifier, so one can replace the other
    let fire: Date
    let item: Item
    let minutes: Int

    var lead: String { minutes == 0 ? "NOW" : "IN \(minutes) MIN" }

    /// The line under the title: where to be, or which call to join.
    var where_: String? {
        if let h = item.meetURL?.host { return h }
        return item.location.isEmpty ? nil : item.location
    }

    /// The half-hour warning is a glance. The two after it are decisions, so they stay
    /// on screen until they are answered.
    var sticky: Bool { minutes <= 5 || item.meetURL != nil }

    /// A call you are about to miss is worth lighting the screen for. A reminder that
    /// something starts in half an hour is not worth waking a Mac you walked away from.
    var wakesDisplay: Bool { minutes <= 5 && (item.meetURL != nil || minutes == 0) }
}

/// Alerts 30 minutes and 5 minutes before an event, and at its start.
///
/// The app schedules local notifications rather than writing EKAlarms onto the events.
/// Writing alarms would change the originals and propagate to every other device.
/// Local notifications leave the data alone and can carry the video-call link in the
/// body and in an action button.
///
/// On the Mac those system notifications are only the fallback for a quit app. While
/// Layers runs it raises its own window instead (`AlertWindows`), and withdraws the
/// matching system request shortly before it would have fired, so one event is never
/// announced twice. See the note at the head of `AlertPanel.swift` for why a banner is
/// the wrong shape for a meeting alert. On the phone the system banner is right and is
/// left alone: there the app is almost always in the background.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private let center = UNUserNotificationCenter.current()
    private let category = "LAYERS_EVENT"
    /// The system caps how many pending notifications it keeps, so fill from the soonest.
    private let maxPending = 60
    private let offsets = Config.alertOffsets
    private var asked = false
    private var authorized = false
    /// Alerts the running app will raise itself, soonest first.
    private var queue: [EventAlert] = []
    private var armed = Set<String>()
    private var raised = Set<String>()
    private var ticker: Timer?

    /// Awaited, not fired and forgotten. `add` is refused outright while the answer to
    /// the permission prompt is still outstanding, and it reports that through a
    /// completion handler nobody was reading, so the first run scheduled nothing at all
    /// and looked identical to a run with no events.
    func start() async {
        if !asked {
            asked = true
            center.delegate = self
            let join = UNNotificationAction(identifier: "JOIN", title: "Join", options: [.foreground])
            center.setNotificationCategories([
                UNNotificationCategory(identifier: category, actions: [join],
                                       intentIdentifiers: [], options: [])
            ])
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        // Re-read every time, so granting permission in System Settings after a refusal
        // takes effect on the next load rather than only after a relaunch.
        if !authorized {
            authorized = await center.notificationSettings().authorizationStatus == .authorized
        }
    }

    func schedule(_ items: [Item]) {
        // Only the fallback notification needs permission. The window Layers raises
        // itself needs none, so a refused prompt must not cost the alerts as well.
        //
        // And without permission every `add` fails silently, so clearing what is
        // already pending would be pure loss.
        if authorized { center.removeAllPendingNotificationRequests() }
        let now = Date()
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        let upcoming = items
            .filter { !$0.isAllDay && $0.start > now && $0.start < horizon }
            .sorted { $0.start < $1.start }

        // Alerts that already fired are kept for a few minutes: a Mac asleep at the time
        // showed nothing, and the window is still worth raising on the way back.
        let missable = now.addingTimeInterval(-5 * 60)
        var due: [EventAlert] = []
        var made = 0
        for item in upcoming {
            for m in offsets {
                let fire = item.start.addingTimeInterval(TimeInterval(-m * 60))
                if fire > missable { due.append(EventAlert(id: "\(item.ekID)-\(m)", fire: fire,
                                                          item: item, minutes: m)) }
                guard authorized, made < maxPending, fire > now else { continue }

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
                // Every alert makes a sound. Silent, a banner is five seconds of
                // something moving at the edge of a screen you were not looking at,
                // which is exactly the alert you needed to hear.
                c.sound = .default
                // Time-sensitive alerts break through a Focus and stay on screen rather
                // than being dropped after five seconds.
                c.interruptionLevel = .timeSensitive

                let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let req = UNNotificationRequest(
                    identifier: "\(item.ekID)-\(m)",
                    content: c,
                    trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
                center.add(req)
                made += 1
            }
        }

        #if os(macOS)
        queue = due.sorted { $0.fire < $1.fire }
        arm()
        #endif
    }

    #if os(macOS)
    /// One repeating check rather than one timer per alert. A timer set for a moment the
    /// Mac sleeps through never runs, and nothing is left to notice it was missed; a
    /// check that keeps coming round sees the miss on the other side of the sleep.
    private func arm() {
        guard ticker == nil else { tick(); return }
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        // .common, or the checks stop for as long as a menu or a scroll is held open.
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.tick()
            }
        tick()
    }

    private func tick() {
        let now = Date()
        for a in queue where !raised.contains(a.id) {
            let wait = a.fire.timeIntervalSince(now)
            if wait <= 0 {
                raise(a)                       // due, or missed while the Mac slept
            } else if wait < 90, !armed.contains(a.id) {
                armed.insert(a.id)
                // Withdraw the system request well before it would fire, so the window
                // replaces the banner rather than joining it.
                center.removePendingNotificationRequests(withIdentifiers: [a.id])
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    self?.raise(a)
                }
            }
        }
    }

    /// Ids of alerts already raised are kept for the life of the process. They are short
    /// and few, and forgetting one means raising the same alert twice on the next check.
    private func raise(_ a: EventAlert) {
        guard !raised.contains(a.id) else { return }
        raised.insert(a.id)
        center.removePendingNotificationRequests(withIdentifiers: [a.id])
        Task { @MainActor in AlertWindows.shared.raise(a) }
    }
    #endif

    /// Show alerts even when the app is frontmost. Five minutes before a call you need
    /// to know regardless of what you are looking at.
    ///
    /// On the Mac this is the case a withdrawn request could not cover — the app was
    /// asleep or busy when the alert came due — so the banner still stands in.
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
