import EventKit
import Foundation

struct Item: Identifiable {
    let id = UUID()
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var source: Source
    var calendar: String
    var alsoIn: [String] = []      // other calendars holding the same event
    var writable: Bool
    var ekID: String
    var location: String = ""
    var notes: String = ""
    var url: URL?
    var account: String = ""       // account this event lives in, used for the web link

    /// Video-call link. Meet, Zoom and Teams links turn up in the URL field, the
    /// location field or the notes, so all three are searched.
    var meetURL: URL? {
        let hosts = Config.meetingHosts
        if let u = url, let h = u.host, hosts.contains(where: { h.contains($0) }) { return u }
        for text in [location, notes, url?.absoluteString ?? ""] where !text.isEmpty {
            let re = try? NSRegularExpression(pattern: #"https?://[^\s<>"\)\]]+"#)
            let ns = NSRange(text.startIndex..., in: text)
            for m in re?.matches(in: text, range: ns) ?? [] {
                guard let r = Range(m.range, in: text) else { continue }
                let str = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
                if let u = URL(string: str), let h = u.host, hosts.contains(where: { h.contains($0) }) { return u }
            }
        }
        return nil
    }

    /// Opens this date in that account's web calendar. Google accepts authuser, so the
    /// right account opens regardless of which one the browser signed into first.
    var sourceLink: URL? {
        let c = Calendar.current
        let y = c.component(.year, from: start), m = c.component(.month, from: start), d = c.component(.day, from: start)
        if source == .work {
            return URL(string: "https://outlook.office.com/calendar/view/day")
        }
        guard account.contains("@") else {
            return URL(string: "https://calendar.google.com/calendar/r/day/\(y)/\(m)/\(d)")
        }
        let esc = account.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? account
        return URL(string: "https://calendar.google.com/calendar/r/day/\(y)/\(m)/\(d)?authuser=\(esc)")
    }

    /// Whether to draw this as a bar running across days. The test is whether it
    /// crosses a day boundary, not whether it is all-day: in one real month, four of
    /// seven multi-day events had a start time (one began at 23:00).
    var spansDays: Bool { isAllDay || !Calendar.current.isDate(start, inSameDayAs: end) }
}

struct Note: Identifiable {
    let id = UUID()
    var label: String       // Pinboard / Done / Due
    var text: String
    var day: Date
    var time: String?
    var at: Date?          // where to place it on the axis; for captures, the creation time
    var isDue: Bool = false
}

struct CalendarChoice: Identifiable, Hashable {
    let id: String
    let title: String
    let source: Source
    let account: String
    /// The calendar title is often the address itself, so avoid printing it twice.
    var label: String { account.isEmpty || account == title ? title : "\(title) · \(account)" }
}

@MainActor
final class CalendarData: ObservableObject {
    @Published var items: [Item] = []
    @Published var notes: [Date: [Note]] = [:]
    @Published var workouts: [Date: Workout] = [:]
    @Published var journalNotes: [Date: [JournalNote]] = [:]
    @Published var hidden: Set<Source> = []
    /// Calendars that accept new events. Subscribed holiday feeds are excluded.
    @Published var writableCalendars: [CalendarChoice] = []
    @Published var status = "Loading"

    private let store = EKEventStore()
    private let cal = Calendar.current

    /// Only the Pinboard list belongs on the calendar. The other lists are backlogs
    /// (books to read, songs, recipes to try) and must not be scattered across dates.
    private let noteLists = Config.noteLists

    func day(_ d: Date) -> Date { cal.startOfDay(for: d) }

    func load(from: Date, to: Date) async {
        // Do not re-ask when access is already granted; requesting unconditionally
        // pops the system dialog on every launch.
        let before = EKEventStore.authorizationStatus(for: .event)
        let ok = before == .fullAccess
            ? true
            : (try? await store.requestFullAccessToEvents()) ?? false
        let remOK = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
            ? true
            : (try? await store.requestFullAccessToReminders()) ?? false
        // Always leave a trace when access fails, otherwise "waiting on the dialog"
        // and "silently denied" look identical from outside.
        if !ok {
            note(["phase": "denied", "before": before.rawValue,
                  "after": EKEventStore.authorizationStatus(for: .event).rawValue,
                  "reminders": remOK])
            status = "Calendar access denied"
            return
        }

        let cals = store.calendars(for: .event)
        writableCalendars = cals.filter(\.allowsContentModifications)
            .map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title,
                                  source: Self.group($0), account: Self.account($0)) }
            .sorted { $0.source.rawValue == $1.source.rawValue ? $0.title < $1.title
                                                              : $0.source.rawValue < $1.source.rawValue }
        let raw = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))

        // Public holidays arrive from four subscribed calendars, so the same day
        // shows up three times over
        var seen = Set<String>()
        var list: [Item] = []
        for e in raw {
            let key = "\(day(e.startDate).timeIntervalSince1970)|\(e.isAllDay)|\(Self.norm(e.title ?? ""))"
            if seen.contains(key) { continue }
            seen.insert(key)
            list.append(Item(title: (e.title ?? "").trimmingCharacters(in: .whitespaces),
                             start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                             source: Self.group(e.calendar), calendar: e.calendar.title,
                             writable: e.calendar.allowsContentModifications,
                             ekID: e.eventIdentifier ?? "",
                             location: e.location ?? "", notes: e.notes ?? "", url: e.url,
                             account: Self.account(e.calendar)))
        }
        items = Self.merge(list)
        status = "\(items.count) events · \(cals.count) calendars"

        if remOK { await loadReminders() }
        loadJournal(from: from, to: to)
        dumpStatus(cals.count, remOK)
    }

    /// Debug dump of what the app actually read, for checking without seeing the screen.
    private func note(_ o: [String: Any]) {
        #if os(macOS)
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/calendar-bridge/layers-status.json")
        try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        #endif
    }

    /// Records what the app actually read, for checking without seeing the screen.
    private func dumpStatus(_ calCount: Int, _ remOK: Bool) {
        var per: [String: Int] = [:]
        for i in items { per[i.source.rawValue, default: 0] += 1 }
        let merged = items.filter { !$0.alsoIn.isEmpty }.map { "\($0.title) +\($0.alsoIn.count)" }
        let spans = items.filter(\.spansDays).map { "\(Fmt.hm($0.start)) \($0.title)" }
        let chips = workouts.values.compactMap { $0.chip?.level }
        let out: [String: Any] = [
            "calendars": calCount, "remindersAccess": remOK,
            "items": items.count, "bySource": per,
            "merged": merged, "spanning": spans.count,
            "workoutDays": workouts.count,
            "workoutDone": chips.filter { $0 == .done }.count,
            "workoutSoft": chips.filter { $0 == .soft }.count,
            "workoutPlan": chips.filter { $0 == .plan }.count,
            "noteDays": notes.count, "journalNoteDays": journalNotes.count,
            "withLocation": items.filter { !$0.location.isEmpty }.count,
            "withURL": items.filter { $0.url != nil }.count,
            "withMeetLink": items.filter { $0.meetURL != nil }.count,
            "meetSamples": items.compactMap { i in i.meetURL.map { "\(i.title.prefix(24)) → \($0.host ?? "")" } }.prefix(6).map { $0 },
            "locationSamples": items.filter { !$0.location.isEmpty }
                .prefix(6).map { "\($0.title.prefix(20)) @ \($0.location.prefix(40))" },
            "accounts": Array(Set(items.map(\.account))).sorted(),
        ]
        note(out)
    }

    // Same day, same time and a shared meaningful word means one event entered into two
    // accounts. One fitness class read "FS8 class" in one account and
    // "FS8 Siglap - FS8 ReformX" in the other, so exact titles never matched.
    // Words that recur across unrelated events ("payment", "birthday") are not evidence:
    // two separate payments on one day must not merge.
    private static let generic = Config.genericWords

    private static func words(_ t: String) -> Set<String> {
        let parts = t.lowercased().components(separatedBy: CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "가"..."힣")).inverted)
        return Set(parts.filter { $0.count >= 3 && !generic.contains($0) })
    }

    private static func norm(_ t: String) -> String {
        String(t.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(34))
    }

    static func merge(_ list: [Item]) -> [Item] {
        var kept: [Item] = []
        var slots: [String: [Int]] = [:]
        let c = Calendar.current
        for e in list {
            let slot = "\(c.startOfDay(for: e.start).timeIntervalSince1970)|\(e.isAllDay ? "" : "\(c.component(.hour, from: e.start)):\(c.component(.minute, from: e.start))")"
            let mine = words(e.title)
            if let idx = slots[slot]?.first(where: { !words(kept[$0].title).isDisjoint(with: mine) }) {
                kept[idx].alsoIn.append(e.calendar)
                if e.title.count > kept[idx].title.count { kept[idx].title = e.title }
                continue
            }
            kept.append(e)
            slots[slot, default: []].append(kept.count - 1)
        }
        return kept
    }

    /// Account address. For Google, the calendar or source title is usually the address.
    static func account(_ c: EKCalendar) -> String {
        if c.title.contains("@") { return c.title }
        if c.source.title.contains("@") { return c.source.title }
        return ""
    }

    static func group(_ c: EKCalendar) -> Source {
        for rule in Config.calendarRules {
            switch rule.match {
            case .titleIs(let s) where c.title == s: return rule.group
            case .titleContains(let s) where c.title.lowercased().contains(s.lowercased()): return rule.group
            case .isExchange where c.source.sourceType == .exchange: return rule.group
            default: continue
            }
        }
        return .personal   // everything unmatched, including shared calendars
    }

    private func loadReminders() async {
        let lists = store.calendars(for: .reminder).filter { noteLists.contains($0.title) }
        guard !lists.isEmpty else { return }
        let found: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: store.predicateForReminders(in: lists)) { cont.resume(returning: $0 ?? []) }
        }
        let hm = DateFormatter(); hm.dateFormat = "HH:mm"
        var out: [Date: [Note]] = [:]
        for r in found {
            // The completion date is only when a script processed the item.
            // The truth about when a thought arrived is the creation date.
            guard let created = r.creationDate else { continue }
            let d = day(created)
            out[d, default: []].append(Note(label: r.calendar.title, text: r.title ?? "",
                                            day: d, time: hm.string(from: created), at: created))
            // A due date set apart from capture is a real deadline: show it there too.
            if let due = r.dueDateComponents.flatMap({ cal.date(from: $0) }), day(due) != d {
                out[day(due), default: []].append(Note(label: "Due", text: r.title ?? "",
                                                       day: day(due), time: nil, at: nil, isDue: true))
            }
        }
        notes = out
    }

    private func loadJournal(from: Date, to: Date) {
        var w: [Date: Workout] = [:], n: [Date: [JournalNote]] = [:]
        var d = day(from)
        while d <= to {
            let (wo, notes) = Journal.load(d)
            if let wo { w[d] = wo }
            if !notes.isEmpty { n[d] = notes }
            d = cal.date(byAdding: .day, value: 1, to: d)!
        }
        workouts = w
        journalNotes = n
    }

    // ── Writing ─────────────────────────────────────
    // Saving through EventKit travels over CalDAV and Exchange back to Google and
    // Outlook. Only subscribed holiday calendars are read-only and must be blocked.
    enum WriteError: LocalizedError {
        case notFound, readOnly, noCalendar
        var errorDescription: String? {
            switch self {
            case .notFound:   return "Could not find that event any more. Try reloading."
            case .readOnly:   return "This is a subscribed calendar and cannot be changed."
            case .noCalendar: return "Pick a calendar first."
            }
        }
    }

    func create(title: String, start: Date, end: Date, allDay: Bool, calendarID: String) throws {
        guard let c = store.calendar(withIdentifier: calendarID), c.allowsContentModifications
        else { throw WriteError.noCalendar }
        let e = EKEvent(eventStore: store)
        e.calendar = c
        e.title = title
        e.isAllDay = allDay
        e.startDate = start
        e.endDate = end
        try store.save(e, span: .thisEvent, commit: true)
    }

    func save(_ item: Item, title: String, start: Date, end: Date, allDay: Bool) throws {
        guard item.writable else { throw WriteError.readOnly }
        guard let e = store.event(withIdentifier: item.ekID) else { throw WriteError.notFound }
        e.title = title
        e.isAllDay = allDay
        e.startDate = start
        e.endDate = end
        // Recurring events change only this occurrence; touching later ones is
        // a much bigger accident to recover from.
        try store.save(e, span: .thisEvent, commit: true)
    }

    func delete(_ item: Item) throws {
        guard item.writable else { throw WriteError.readOnly }
        guard let e = store.event(withIdentifier: item.ekID) else { throw WriteError.notFound }
        try store.remove(e, span: .thisEvent, commit: true)
    }

    // ── Queries used by the views ───────────────────
    func visible(_ i: Item) -> Bool { !hidden.contains(i.source) }

    /// Events listed inside a day cell. Only those that finish the same day.
    func timed(on d: Date) -> [Item] {
        items.filter { visible($0) && !$0.spansDays && cal.isDate($0.start, inSameDayAs: d) }
            .sorted { $0.start < $1.start }
    }

    /// Bar segments crossing a week. Clipped at week edges; overlaps get their own lane.
    struct Segment: Identifiable {
        let id = UUID()
        var item: Item
        var startCol: Int
        var endCol: Int
        var lane: Int
        var openLeft: Bool
        var openRight: Bool
    }

    func segments(weekStart w0: Date) -> [Segment] {
        let w6 = cal.date(byAdding: .day, value: 6, to: w0)!
        let hits = items.filter { visible($0) && $0.spansDays && day($0.end) >= w0 && day($0.start) <= w6 }
        var segs = hits.map { e -> Segment in
            let s = day(e.start), t = day(e.end)
            let sc = max(0, cal.dateComponents([.day], from: w0, to: s).day ?? 0)
            let ec = min(6, cal.dateComponents([.day], from: w0, to: t).day ?? 0)
            return Segment(item: e, startCol: sc, endCol: ec, lane: 0, openLeft: s < w0, openRight: t > w6)
        }
        segs.sort { $0.startCol != $1.startCol ? $0.startCol < $1.startCol
                                               : ($0.endCol - $0.startCol) > ($1.endCol - $1.startCol) }
        var lanes: [[Segment]] = []
        for i in segs.indices {
            let g = segs[i]
            if let li = lanes.firstIndex(where: { row in row.allSatisfy { g.startCol > $0.endCol || g.endCol < $0.startCol } }) {
                segs[i].lane = li; lanes[li].append(segs[i])
            } else {
                segs[i].lane = lanes.count; lanes.append([segs[i]])
            }
        }
        return segs
    }

    func laneCount(weekStart w0: Date) -> Int {
        (segments(weekStart: w0).map(\.lane).max() ?? -1) + 1
    }
}
