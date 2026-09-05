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
    /// Set when the event carries a recurrence rule, so the editor can say what it is
    /// editing one occurrence of. A label, not the rule: nothing here rewrites a series.
    var recurrence: String?

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

/// The repeats offered when creating an event.
///
/// Deliberately the common few. EventKit can express far more, and an editor that saves
/// a change to one occurrence has no business writing a rule it cannot show afterwards.
enum Repeat: String, CaseIterable, Identifiable {
    case never, daily, weekdays, weekly, biweekly, monthly, yearly
    var id: String { rawValue }

    var label: String {
        switch self {
        case .never:    return "Does not repeat"
        case .daily:    return "Every day"
        case .weekdays: return "Every weekday"
        case .weekly:   return "Every week"
        case .biweekly: return "Every 2 weeks"
        case .monthly:  return "Every month"
        case .yearly:   return "Every year"
        }
    }

    var rule: EKRecurrenceRule? {
        switch self {
        case .never:    return nil
        case .daily:    return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case .weekly:   return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case .biweekly: return EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil)
        case .monthly:  return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case .yearly:   return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        case .weekdays:
            // Monday is 2 and Friday is 6; EKWeekday counts from Sunday.
            let days = (2...6).compactMap { EKWeekday(rawValue: $0) }.map(EKRecurrenceDayOfWeek.init)
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, daysOfTheWeek: days,
                                    daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                                    daysOfTheYear: nil, setPositions: nil, end: nil)
        }
    }

    /// Names a rule already on an event. Only the shape of it — an event repeating on
    /// three named weekdays still reads as "Weekly", which is what the editor needs to
    /// say and all it is entitled to claim.
    static func name(_ r: EKRecurrenceRule) -> String {
        let n = r.interval
        switch r.frequency {
        case .daily:   return n == 1 ? "daily" : "every \(n) days"
        case .weekly:  return n == 1 ? "weekly" : "every \(n) weeks"
        case .monthly: return n == 1 ? "monthly" : "every \(n) months"
        case .yearly:  return n == 1 ? "yearly" : "every \(n) years"
        @unknown default: return "on a schedule"
        }
    }
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
    /// One store for the whole app. The window is no longer the only thing reading the
    /// calendar — the menu bar keeps reading it after the window has closed — and two
    /// `EKEventStore`s would mean two permission prompts for one app.
    static let shared = CalendarData()

    @Published var items: [Item] = [] { didSet { index() } }
    @Published var notes: [Date: [Note]] = [:]
    @Published var workouts: [Date: Workout] = [:]
    @Published var journalNotes: [Date: [JournalNote]] = [:]
    @Published var hidden: Set<Source> = [] { didSet { index() } }
    /// Calendars that accept new events. Subscribed holiday feeds are excluded.
    @Published var writableCalendars: [CalendarChoice] = []
    @Published var status = "Loading"
    /// Set while a reload is in flight, so a manual refresh can say it heard the ask.
    @Published var refreshing = false

    private let store = EKEventStore()
    private let cal = Calendar.current
    /// The window last asked for, so a refresh can re-read the same one. Without it a
    /// refresh would have to guess which month is on screen.
    private var window: (from: Date, to: Date)?
    /// The window actually read, which is several months wider than the one on screen.
    /// A page turn that lands inside it is a view change and nothing else.
    private var loaded: (from: Date, to: Date)?
    /// Reminders have no window: the whole list is fetched whatever month is showing.
    /// So fetching them again on a page turn was three hundred milliseconds spent
    /// arriving at the same answer, and it was most of what a page turn cost.
    private var remindersLoaded = false

    /// Fired after a load that actually read something. A load already covered fires
    /// nothing, which is the point of it.
    var onLoad: (@MainActor () -> Void)?

    // ── What the grid asks for, worked out once ─────
    // A cell used to filter the whole window to find its own day, and a week row to
    // find its own bars. Forty-two cells and six rows against a window of several
    // hundred events, on every redraw, is the difference between a page turn that lands
    // and one you watch happen.
    private var timedByDay: [Date: [Item]] = [:]
    private var spanningItems: [Item] = []
    private var segsByWeek: [Date: [Segment]] = [:]

    private func index() {
        var byDay: [Date: [Item]] = [:]
        var spans: [Item] = []
        for i in items where visible(i) {
            if i.spansDays { spans.append(i) } else { byDay[day(i.start), default: []].append(i) }
        }
        for k in byDay.keys { byDay[k]?.sort { $0.start < $1.start } }
        timedByDay = byDay
        spanningItems = spans
        segsByWeek = [:]
    }
    private var changeTask: Task<Void, Never>?

    private init() {
        // EventKit says when the local store changed, which is the only notice there is
        // that a sync landed. The grid used to ignore it: only the alert queue listened,
        // so an event added on the phone appeared on the Mac just when you happened to
        // page away and back.
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.storeChanged() }
            }
    }

    /// EventKit sends these in bursts while a sync lands, and publishing the workout
    /// feed causes one of its own, so the reload waits for the burst to end. It settles:
    /// the second pass finds the feed already correct and writes nothing.
    private func storeChanged() {
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.refresh(pullSources: false)
        }
    }

    /// Re-reads whatever is on screen.
    ///
    /// EventKit reads the local store, so this is not itself a fetch from Google or
    /// Outlook: that is the OS's account sync, and `refreshSourcesIfNecessary` is the
    /// only nudge a third-party app is given. It is a request, not a guarantee, so a
    /// refresh that finds nothing new is not necessarily a refresh that failed.
    func refresh(pullSources: Bool = true) async {
        // The read window, not the month on screen: re-reading the narrower one would
        // throw away the margin that makes paging free.
        guard let w = loaded ?? window, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if pullSources { store.refreshSourcesIfNecessary() }
        await load(from: w.from, to: w.to, force: true)
    }

    /// Only the Pinboard list belongs on the calendar. The other lists are backlogs
    /// (books to read, songs, recipes to try) and must not be scattered across dates.
    private let noteLists = Config.noteLists

    func day(_ d: Date) -> Date { cal.startOfDay(for: d) }

    /// The calendar the Mac publishes workout records into. It holds a copy of the
    /// journal, not appointments, so it is read as workouts and never as events.
    static func isWorkoutFeed(_ c: EKCalendar) -> Bool {
        guard let f = Config.workoutFeed else { return false }
        return c.title == f.calendar
            && (c.source.title == f.account || account(c) == f.account || f.account.isEmpty)
    }

    /// Reads a window and turns it into items. Public holidays arrive from four
    /// subscribed calendars, so the same day shows up three times over.
    private func read(from: Date, to: Date) -> [Item] {
        let feeds = store.calendars(for: .event).filter(Self.isWorkoutFeed)
        let raw = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
            .filter { !feeds.contains($0.calendar) }
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
                             account: Self.account(e.calendar),
                             recurrence: e.recurrenceRules?.first.map(Repeat.name)))
        }
        return Self.merge(list)
    }

    /// The coming week, read on its own account. What alerts are built from must not be
    /// what is on screen: `items` follows the month you are looking at, so alerts taken
    /// from it were cancelled outright the moment you paged forward to check something.
    func upcoming(days: Int) -> [Item] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let now = Date()
        return read(from: now, to: cal.date(byAdding: .day, value: days, to: now)!)
    }

    /// How long each phase of the last load took. A reload happens on every page turn,
    /// so where the time goes is not a question to answer by guessing.
    private(set) var timings: [String: Int] = [:]
    private(set) var loadCount = 0
    private func timed<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        let t0 = Date()
        defer { timings[name] = Int(Date().timeIntervalSince(t0) * 1000) }
        return try work()
    }
    private func timedAsync<T>(_ name: String, _ work: () async -> T) async -> T {
        let t0 = Date()
        defer { timings[name] = Int(Date().timeIntervalSince(t0) * 1000) }
        return await work()
    }

    /// Whether a window has already been read, so a caller can decide not to ask.
    func covers(_ from: Date, _ to: Date) -> Bool {
        guard let l = loaded else { return false }
        return l.from <= from && to <= l.to
    }

    /// Reads a window, unless one that contains it has already been read.
    ///
    /// `force` is what a refresh means: read it again whether or not it is covered.
    func load(from: Date, to: Date, force: Bool = false) async {
        window = (from, to)
        if !force, let l = loaded, l.from <= from, to <= l.to { return }
        // Counted, because "the page turn did no work" is the whole claim and there is
        // otherwise no way to see it from outside.
        loadCount += 1
        // Cleared, or a phase that did not run this time reports the last time it did.
        timings = [:]
        let t0 = Date()
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

        let cals: [EKCalendar] = timed("calendars") { store.calendars(for: .event) }
        // The workout feed accepts writes, but only the publisher may use it: an event
        // created there by hand would be deleted on the next reload.
        writableCalendars = cals.filter { $0.allowsContentModifications && !Self.isWorkoutFeed($0) }
            .map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title,
                                  source: Self.group($0), account: Self.account($0)) }
            .sorted { $0.source.rawValue == $1.source.rawValue ? $0.title < $1.title
                                                              : $0.source.rawValue < $1.source.rawValue }
        items = timed("events") { read(from: from, to: to) as [Item] }
        status = "\(items.count) events · \(cals.count) calendars"

        // Nothing about a reminder depends on the window, so it is read once and again
        // only when something says the store changed.
        if remOK, !remindersLoaded || force {
            await timedAsync("reminders") { await loadReminders() }
            remindersLoaded = true
        }
        await timedAsync("journal") { await loadJournal(from: from, to: to) }
        #if os(macOS)
        timed("publish") { publishWorkouts(from: from, to: to) }
        #else
        // The vault is the truth wherever the phone has been given it. The feed the Mac
        // publishes is what stands in until then, and stops mattering after.
        if Journal.journalDir == nil { loadWorkoutFeed(from: from, to: to) }
        #endif
        timings["total"] = Int(Date().timeIntervalSince(t0) * 1000)
        dumpStatus(cals.count, remOK)
        loaded = (from, to)
        onLoad?()
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
        let recorded = workouts.values.filter { $0.chip != nil }.count
        let out: [String: Any] = [
            "calendars": calCount, "remindersAccess": remOK,
            "items": items.count, "bySource": per,
            "merged": merged, "spanning": spans.count,
            "workoutDays": workouts.count,
            "workoutRecorded": recorded,
            // The tags are taken from the journal as written, so what they say is a
            // question about the journal, not about the parser. Printed to be read.
            "workoutTags": workouts.sorted { $0.key > $1.key }.prefix(12).compactMap { d, w in
                w.chip.map { "\(Fmt.ymd(d)) \($0.joined(separator: " · "))" } },
            "noteDays": notes.count, "journalNoteDays": journalNotes.count,
            "withLocation": items.filter { !$0.location.isEmpty }.count,
            "withURL": items.filter { $0.url != nil }.count,
            "withMeetLink": items.filter { $0.meetURL != nil }.count,
            "meetSamples": items.compactMap { i in i.meetURL.map { "\(i.title.prefix(24)) → \($0.host ?? "")" } }.prefix(6).map { $0 },
            "locationSamples": items.filter { !$0.location.isEmpty }
                .prefix(6).map { "\($0.title.prefix(20)) @ \($0.location.prefix(40))" },
            "accounts": Array(Set(items.map(\.account))).sorted(),
            "ms": timings, "loads": loadCount,
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

    /// Parses the journal off the main thread.
    ///
    /// On the Mac a window is seventy-five local files. On the phone it is seventy-five
    /// round trips to another app's file provider, some of which may have to be fetched
    /// from iCloud first, and doing that inline freezes the calendar for as long as it
    /// takes. `Journal` keeps what it parsed, so only a note that changed is read twice.
    private func loadJournal(from: Date, to: Date) async {
        guard let dir = Journal.journalDir else { workouts = [:]; journalNotes = [:]; return }
        var days: [Date] = []
        var d = day(from)
        while d <= to { days.append(d); d = cal.date(byAdding: .day, value: 1, to: d)! }

        let parsed = await Task.detached(priority: .userInitiated) {
            var w: [Date: Workout] = [:], n: [Date: [JournalNote]] = [:]
            for day in days {
                let (wo, notes) = Journal.load(day, in: dir)
                if let wo { w[day] = wo }
                if !notes.isEmpty { n[day] = notes }
            }
            return (w, n)
        }.value
        workouts = parsed.0
        journalNotes = parsed.1
    }

    // ── The workout feed ────────────────────────────
    // The journal is a folder in Obsidian's iCloud container. macOS can read it and iOS
    // is given no path to it at all, so the Mac copies what it parsed into a calendar of
    // its own and the phone reads that. The copy carries only what the two views show:
    // the tags and the record line.
    //
    // This is a one-way copy of a file the phone cannot see, not a sync. If the phone
    // is ever taught to read the vault itself, both halves of this go away and nothing
    // above them changes, because both produce the same `[Date: Workout]`.

    private func workoutFeedCalendar() -> EKCalendar? {
        store.calendars(for: .event).first(where: Self.isWorkoutFeed)
    }

    #if os(macOS)
    /// Writes the journal's records into the feed: one all-day event per recorded day,
    /// tags as the title and the record line as the notes.
    ///
    /// The journal is the truth, so a day whose record changed is rewritten and a day
    /// whose record went away is deleted. That is only safe because nothing else writes
    /// here, and only correct while the journal can actually be read: an unreachable
    /// vault parses as no workouts at all, which would otherwise empty the feed and take
    /// the phone's history with it.
    private func publishWorkouts(from: Date, to: Date) {
        guard Config.workoutFeed != nil, Journal.available,
              let feed = workoutFeedCalendar(), feed.allowsContentModifications else { return }

        var existing: [Date: EKEvent] = [:]
        var dirty = false
        for e in store.events(matching: store.predicateForEvents(withStart: from, end: to,
                                                                 calendars: [feed])) {
            let d = day(e.startDate)
            // Two events on one day means an earlier write was interrupted part way.
            if let older = existing[d] {
                try? store.remove(older, span: .thisEvent, commit: false); dirty = true
            }
            existing[d] = e
        }

        var d = day(from)
        let last = day(to)
        while d <= last {
            defer { d = cal.date(byAdding: .day, value: 1, to: d)! }
            let want = workouts[d]?.chip.map {
                (title: $0.map(Workout.label).joined(separator: ", "),
                 note: workouts[d]?.actual ?? "")
            }
            let have = existing[d]
            switch (want, have) {
            case (nil, nil):
                continue
            case (nil, let e?):
                try? store.remove(e, span: .thisEvent, commit: false); dirty = true
            case (let w?, let e?):
                guard e.title != w.title || (e.notes ?? "") != w.note else { continue }
                e.title = w.title
                e.notes = w.note.isEmpty ? nil : w.note
                try? store.save(e, span: .thisEvent, commit: false); dirty = true
            case (let w?, nil):
                let e = EKEvent(eventStore: store)
                e.calendar = feed
                e.isAllDay = true
                e.startDate = d
                e.endDate = d
                e.title = w.title
                e.notes = w.note.isEmpty ? nil : w.note
                try? store.save(e, span: .thisEvent, commit: false); dirty = true
            }
        }
        // One commit, so a month's catching up is one sync rather than thirty, and so a
        // reload that changed nothing does not touch the calendar at all.
        if dirty { try? store.commit() }
    }
    #else
    /// Rebuilds workouts from the feed the Mac publishes. The tags come back as they
    /// were written; the checkbox-only days and the recovery figure do not travel,
    /// because neither is shown from a record the phone did not parse.
    private func loadWorkoutFeed(from: Date, to: Date) {
        guard let feed = workoutFeedCalendar() else { return }
        var out: [Date: Workout] = [:]
        for e in store.events(matching: store.predicateForEvents(withStart: from, end: to,
                                                                 calendars: [feed])) {
            var w = Workout()
            w.recorded = true
            w.actualTags = (e.title ?? "").components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            w.actual = e.notes ?? ""
            out[day(e.startDate)] = w
        }
        workouts = out
    }
    #endif

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

    func create(title: String, start: Date, end: Date, allDay: Bool,
                location: String, repeats: Repeat, calendarID: String) throws {
        guard let c = store.calendar(withIdentifier: calendarID), c.allowsContentModifications
        else { throw WriteError.noCalendar }
        let e = EKEvent(eventStore: store)
        e.calendar = c
        e.title = title
        e.isAllDay = allDay
        e.startDate = start
        e.endDate = end
        e.location = location.isEmpty ? nil : location
        if let r = repeats.rule { e.addRecurrenceRule(r) }
        // A new series is written whole. `.thisEvent` on an event that carries a rule
        // saves the first occurrence and leaves the rest unwritten.
        try store.save(e, span: repeats == .never ? .thisEvent : .futureEvents, commit: true)
    }

    /// Every occurrence of a recurring event shares one `eventIdentifier`, so
    /// `store.event(withIdentifier:)` does not name the occurrence that was opened —
    /// it resolves to whichever one EventKit feels like, in practice usually the
    /// series' first. Saving or deleting "this event" on that wrong instance changes a
    /// different day and leaves the one you opened untouched, which reads as the write
    /// having silently failed. The fix is to ask for the identifier and the moment
    /// together: a narrow predicate around `item.start` plus a match on the id can only
    /// return the occurrence actually on screen.
    private func occurrence(_ item: Item) -> EKEvent? {
        let near = store.predicateForEvents(
            withStart: cal.date(byAdding: .minute, value: -1, to: item.start)!,
            end: cal.date(byAdding: .minute, value: 1, to: item.start)!, calendars: nil)
        return store.events(matching: near).first { $0.eventIdentifier == item.ekID }
    }

    func save(_ item: Item, title: String, start: Date, end: Date, allDay: Bool,
              location: String) throws {
        guard item.writable else { throw WriteError.readOnly }
        guard let e = occurrence(item) else { throw WriteError.notFound }
        e.title = title
        e.isAllDay = allDay
        e.startDate = start
        e.endDate = end
        e.location = location.isEmpty ? nil : location
        // Recurring events change only this occurrence; touching later ones is
        // a much bigger accident to recover from. The repeat itself is therefore not
        // editable here — it belongs to the series, not to the day you opened.
        try store.save(e, span: .thisEvent, commit: true)
    }

    func delete(_ item: Item) throws {
        guard item.writable else { throw WriteError.readOnly }
        guard let e = occurrence(item) else { throw WriteError.notFound }
        try store.remove(e, span: .thisEvent, commit: true)
    }

    // ── Queries used by the views ───────────────────
    func visible(_ i: Item) -> Bool { !hidden.contains(i.source) }

    /// Events listed inside a day cell. Only those that finish the same day.
    func timed(on d: Date) -> [Item] { timedByDay[day(d)] ?? [] }

    /// Events crossing this day, for the day view's all-day band.
    func spanning(on d: Date) -> [Item] {
        let d0 = day(d)
        return spanningItems.filter { day($0.start) <= d0 && d0 <= day($0.end) }
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

    /// Memoised. Six week rows each ask for their own bars on every redraw, and each
    /// ask used to be a pass over the whole window plus a sort plus lane packing.
    func segments(weekStart w0: Date) -> [Segment] {
        if let hit = segsByWeek[w0] { return hit }
        let out = buildSegments(weekStart: w0)
        segsByWeek[w0] = out
        return out
    }

    private func buildSegments(weekStart w0: Date) -> [Segment] {
        let w6 = cal.date(byAdding: .day, value: 6, to: w0)!
        let hits = spanningItems.filter { day($0.end) >= w0 && day($0.start) <= w6 }
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
