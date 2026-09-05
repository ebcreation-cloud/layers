import Foundation

// Parses the Obsidian daily journal. Ported from workout_parse.py.
//
// Plan and execution must stay separate. A Templater template injects the planned
// session into every note, so reading the plan alone makes it look like a workout
// happened every day. The only real evidence is the record line and the checkboxes:
// in one sample month, 11 days out of 26 were actually filled in.

struct Workout: Sendable {
    var planned: String = ""
    /// The record line, minus the tags written at its head. It can be empty on a day
    /// whose record was nothing but its tags, which is why it is not the evidence.
    var actual: String = ""
    /// Taken from the journal as written. Nothing here was inferred.
    var actualTags: [String] = []
    /// Whether the record line was filled in at all. That, not the text, is the evidence.
    var recorded = false
    var postureDone: [String] = []
    var stretchDone: [String] = []
    var recovery: Int?
    var noteTitle: String = ""

    var didMain: Bool { recorded }

    /// Tags are shown as they were written. This table exists only for the two the
    /// parser still invents — a recorded day with no tag on it, and a day evidenced by
    /// nothing but a ticked checkbox — and for notes written before tags were taken
    /// verbatim, which named their sessions in Korean.
    static let en = ["하체A": "Lower A", "하체B": "Lower B", "상체당기기": "Upper Pull",
        "상체밀기": "Upper Push", "코어": "Core", "필라테스": "Pilates", "골프": "Golf",
        "유산소": "Cardio", "자세교정": "Posture", "휴식": "Rest", "스트레칭": "Stretch", "운동": "Workout"]
    static func label(_ t: String) -> String { en[t] ?? t }

    /// A day recorded as rest was recorded, so it is not a plan; but nothing was done,
    /// so it is not a workout either. Tags are taken as written, so the several ways of
    /// writing it have to be recognised here rather than normalised on the way in.
    static func isRest(_ t: String) -> Bool {
        let s = t.lowercased().trimmingCharacters(in: .whitespaces)
        if ["rest", "rest day", "휴식", "쉼", "off day"].contains(s) { return true }
        // The one place a tag is read rather than repeated, because it decides whether
        // there is a chip at all. "오늘 그냥 쉬었어" is a whole record line and so a whole
        // tag under the rule above, and a rest day drawn as a workout is the one thing
        // this calendar must not do.
        return s.range(of: #"쉬었|쉬는\s*날|\brest\b"#, options: .regularExpression) != nil
    }

    /// What was actually done, or nothing at all.
    ///
    /// The calendar is a record of the past, not a statement of intent, so a plan is
    /// not shown — and it especially must not be, because the journal template injects
    /// a planned session into every daily note, which made it look like a workout
    /// happened every day. The only evidence is the record line and the checkboxes.
    ///
    /// A rest day is not shown either. It used to be, in grey, on the argument that
    /// being recorded made it worth a mark; but nothing was done, and a blank day says
    /// that more plainly than a chip saying so.
    var chip: [String]? {
        if recorded {
            var tags = actualTags
            // A record line that is nothing but detail. It was written, so it counts,
            // but it names nothing.
            if tags.isEmpty { return ["운동"] }
            // "Rest" next to a session name is a remark about part of the day.
            // A rest day names nothing else.
            if tags.count > 1 { tags.removeAll(where: Workout.isRest) }
            if tags.isEmpty || tags.allSatisfy(Workout.isRest) { return nil }
            return tags
        }
        if !stretchDone.isEmpty { return ["스트레칭"] }
        if !postureDone.isEmpty { return ["자세교정"] }
        return nil
    }
}

struct JournalNote: Identifiable, Sendable {
    let id = UUID()
    var label: String      // Pinboard / Done
    var text: String
    var time: String?
}

enum Journal {
    // The vault lives inside Obsidian's iCloud container. On macOS that is a path like
    // any other. On iOS it belongs to another app and there is no path to it at all, so
    // the folder is the one the person handed over in the Files app. Nothing below
    // knows the difference: it is given a directory and reads it.
    #if os(macOS)
    static let vault = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(Config.vaultPath ?? "")
    @MainActor static var journalDir: URL? {
        Config.vaultPath == nil ? nil : vault.appendingPathComponent(Config.journalFolder)
    }
    #else
    @MainActor static var journalDir: URL? { Vault.shared.journalDir }
    #endif

    /// Whether the journal can be read at all. An unreachable vault and a vault with
    /// nothing recorded in it look identical from the outside, and one of them must not
    /// be allowed to empty the calendar feed. See `CalendarData.publishWorkouts`.
    @MainActor static var available: Bool {
        guard let d = journalDir else { return false }
        return FileManager.default.fileExists(atPath: d.path)
    }

    /// The tags at the head of a record line, taken exactly as they were written.
    ///
    /// There is no vocabulary here on purpose. A fixed list could only ever recognise
    /// the sessions someone thought of in advance: "swimming, yoga" was recorded on
    /// 3 September and matched nothing, so the day showed a bare "workout". Guessing
    /// from the exercise names was worse — 25 August was a Lower B session logged as
    /// "bulgarian split squat", which reads as Lower A and was tagged as one. What is
    /// written at the head of the line is a statement, not evidence to be weighed.
    ///
    /// The rule: everything up to the first ` - ` or ` | ` is tags, split on `,` `/`
    /// `+`. A line with no separator is all tags. Detail belongs after the separator,
    /// or on the indented bullets under the line, which `load` already leaves out.
    ///
    ///     - 기록: Leg B, Core - RDL 원판 12.5kg 3x10. 허리 중립 잘 지켰다
    ///     - 기록: swimming, yoga
    ///
    /// Only the separator is required to be spaced, because a bare hyphen is part of
    /// words that turn up in tags ("push-up", "T-spine").
    private static let separator = #"\s+[-–—|]\s+"#
    private static let splitters = CharacterSet(charactersIn: ",/+·&")

    static func recordTags(_ text: String) -> (tags: [String], rest: String) {
        var head = Substring(text), rest = Substring("")
        if let r = text.range(of: separator, options: .regularExpression) {
            head = text[..<r.lowerBound]
            rest = text[r.upperBound...]
        }
        var tags: [String] = []
        var cursor = head.startIndex
        while cursor < head.endIndex {
            let end = head[cursor...].firstIndex { $0.unicodeScalars.count == 1
                && splitters.contains($0.unicodeScalars.first!) } ?? head.endIndex
            let t = head[cursor..<end].trimmingCharacters(in: .whitespaces)
            // A tag names a session. It does not carry a weight or a rep count, and it
            // is short. Without this, a day written without a separator would turn its
            // whole record into one enormous tag rather than into a note.
            if !t.isEmpty, t.count > 20 || t.contains(where: \.isNumber) {
                // Nothing before it was a tag either, so the line is all note and is
                // handed back exactly as it came in.
                if tags.isEmpty { return ([], text) }
                let tail = head[cursor...].trimmingCharacters(in: .whitespaces)
                return (tags, [tail, String(rest)].filter { !$0.isEmpty }.joined(separator: " "))
            }
            if !t.isEmpty, !tags.contains(t) { tags.append(t) }
            cursor = end < head.endIndex ? head.index(after: end) : end
        }
        return (tags, String(rest))
    }

    static func stripMD(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\*+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[\[([^\]|]+)(\|[^\]]+)?\]\]"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " .·-\n"))
    }

    /// dotAll belongs only to whole-section lifts. Left on while matching the record
    /// line, the trailing `.*` swallows the rest of the file and every day looks logged.
    private static func firstMatch(_ text: String, _ pattern: String, dotAll: Bool = true) -> String? {
        var opts: NSRegularExpression.Options = [.anchorsMatchLines]
        if dotAll { opts.insert(.dotMatchesLineSeparators) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }

    /// A file iCloud has not brought down yet is listed under a name of its own:
    /// ".2026-09-04.md.icloud", a placeholder standing where the note will be. The name
    /// underneath is what everything else here expects to see.
    private static func realName(_ n: String) -> String {
        guard n.hasPrefix("."), n.hasSuffix(".icloud") else { return n }
        return String(n.dropFirst().dropLast(".icloud".count))
    }

    /// Reads a note, downloading it first if this is a copy of the vault that has only
    /// ever been listed. Coordinating the read is what waits for the download; asking
    /// for the file directly just fails while it is a placeholder.
    ///
    /// It blocks, so it does not belong on the main thread. `CalendarData` parses the
    /// whole window off it.
    private static func contents(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var out: String?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
            out = try? String(contentsOf: u, encoding: .utf8)
        }
        return out
    }

    /// Reads one day's journal entry and returns its workout and notes.
    static func load(_ day: Date, in dir: URL) -> (Workout?, [JournalNote]) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let prefix = f.string(from: day)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return (nil, []) }
        // Korean filenames mix NFD and NFC, so normalise before comparing
        guard let raw = names.sorted().first(where: {
            let n = realName($0).precomposedStringWithCanonicalMapping
            return n.hasPrefix(prefix) && n.hasSuffix(".md")
        }) else { return (nil, []) }
        let name = realName(raw)
        let url = dir.appendingPathComponent(name)
        if let hit = Cache.shared.value(for: url) { return hit }
        guard let body = contents(url) else { return (nil, []) }

        var w = Workout()
        w.noteTitle = stripMD(String(name.precomposedStringWithCanonicalMapping.dropFirst(11).dropLast(3)))

        if let sec = firstMatch(body, #"^##\s*\*{0,2}운동[^\n]*\n(.*?)(?=^##\s|\Z)"#) {
            w.planned = firstMatch(sec, #"오늘 세션:[ \t]*(.*)"#, dotAll: false).map(stripMD) ?? ""
            // \s* after the colon would swallow newlines and capture the next heading
            let record = firstMatch(sec, #"^[ \t]*-[ \t]*기록[ \t]*:[ \t]*(.*(?:\n(?![ \t]*(?:[-*>#]|$)).*)*)"#, dotAll: false).map(stripMD) ?? ""
            w.recorded = !record.isEmpty
            // No fallback to the planned session. The template injects one into every
            // note, so borrowing it whenever the record was unrecognisable was how a
            // day of swimming came to be filed as the leg session nobody did.
            let (written, rest) = recordTags(record)
            w.actualTags = written
            w.actual = stripMD(rest)
            if let r = firstMatch(sec, #"Recovery:\s*_*\s*(\d{1,3})\s*%"#, dotAll: false) { w.recovery = Int(r) }
            w.postureDone = checked(sub(sec, "자세 교정 강화"))
            w.stretchDone = checked(sub(sec, "스트레칭"))
        }

        var notes: [JournalNote] = []
        if let pin = firstMatch(body, #"^##\s*\*{0,2}핀보드[^\n]*\n(.*?)(?=^##\s|\Z)"#) {
            for line in pin.split(separator: "\n") {
                let t = stripMD(String(line))
                guard !t.isEmpty else { continue }
                notes.append(JournalNote(label: "Pinboard", text: t, time: nil))
            }
        }
        if let todo = firstMatch(body, #"^##\s*\*{0,2}Todo list[^\n]*\n(.*?)(?=^##\s|\Z)"#) {
            for line in todo.split(separator: "\n") where line.range(of: #"^\s*-\s*\[[xX]\]"#, options: .regularExpression) != nil {
                let t = stripMD(line.replacingOccurrences(of: #"^\s*-\s*\[[xX]\]\s*"#, with: "", options: .regularExpression))
                if !t.isEmpty { notes.append(JournalNote(label: "Done", text: t, time: nil)) }
            }
        }
        let bare = w.planned.isEmpty && w.actual.isEmpty && !w.recorded
            && w.postureDone.isEmpty && w.stretchDone.isEmpty
        let out = (bare ? nil : w, notes)
        Cache.shared.store(out, for: url)
        return out
    }

    /// Parsed notes, kept between reloads and thrown away when the file changes.
    ///
    /// On the Mac this saves a little work. On the phone it is what makes the thing
    /// usable at all: every note is a round trip to another app's file provider, and a
    /// month is seventy-five of them on every page turn and every return to the app.
    private final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        private var byPath: [String: (stamp: Date, size: Int, value: (Workout?, [JournalNote]))] = [:]

        /// Modification date and size together, because a file provider's clock is not
        /// this device's and a date alone has been known to come back unchanged.
        private func mark(_ url: URL) -> (Date, Int)? {
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let d = v.contentModificationDate else { return nil }
            return (d, v.fileSize ?? 0)
        }

        func value(for url: URL) -> (Workout?, [JournalNote])? {
            guard let (d, n) = mark(url) else { return nil }
            lock.lock(); defer { lock.unlock() }
            guard let hit = byPath[url.path], hit.stamp == d, hit.size == n else { return nil }
            return hit.value
        }

        func store(_ value: (Workout?, [JournalNote]), for url: URL) {
            guard let (d, n) = mark(url) else { return }
            lock.lock(); defer { lock.unlock() }
            byPath[url.path] = (d, n, value)
        }
    }

    private static func sub(_ sec: String, _ name: String) -> String {
        firstMatch(sec, #"^\*"# + NSRegularExpression.escapedPattern(for: name) + #"\*[^\n]*\n(.*?)(?=^\*\S|\Z)"#) ?? ""
    }

    private static func checked(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            guard line.range(of: #"^\s*-\s*\[[xX]\]"#, options: .regularExpression) != nil else { return nil }
            let t = stripMD(line.replacingOccurrences(of: #"^\s*-\s*\[[xX]\]\s*"#, with: "", options: .regularExpression))
            return t.isEmpty ? nil : t
        }
    }
}
