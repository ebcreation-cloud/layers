import Foundation

// Parses the Obsidian daily journal. Ported from workout_parse.py.
//
// Plan and execution must stay separate. A Templater template injects the planned
// session into every note, so reading the plan alone makes it look like a workout
// happened every day. The only real evidence is the record line and the checkboxes:
// in one sample month, 11 days out of 26 were actually filled in.

struct Workout {
    var planned: String = ""
    var plannedTags: [String] = []
    var actual: String = ""
    var actualTags: [String] = []
    var postureDone: [String] = []
    var stretchDone: [String] = []
    var recovery: Int?
    var noteTitle: String = ""

    var didMain: Bool { !actual.isEmpty }

    /// The parser emits Korean tags; they are translated only for display.
    /// Month and day views share this table so neither drifts out of English.
    static let en = ["하체A": "Lower A", "하체B": "Lower B", "상체당기기": "Upper Pull",
        "상체밀기": "Upper Push", "코어": "Core", "필라테스": "Pilates", "골프": "Golf",
        "유산소": "Cardio", "자세교정": "Posture", "휴식": "Rest", "스트레칭": "Stretch", "운동": "Workout"]
    static func label(_ t: String) -> String { en[t] ?? t }

    /// Three steps of one green. The solid fill is only for days with a record line.
    enum Level { case done, soft, plan }
    var chip: (level: Level, tags: [String])? {
        if didMain { return (.done, actualTags.isEmpty ? ["운동"] : actualTags) }
        if !stretchDone.isEmpty { return (.soft, ["스트레칭"]) }
        if !postureDone.isEmpty { return (.soft, ["자세교정"]) }
        if !plannedTags.isEmpty { return (.plan, plannedTags) }
        return nil
    }
}

struct JournalNote: Identifiable {
    let id = UUID()
    var label: String      // Pinboard / Done
    var text: String
    var time: String?
}

enum Journal {
    // The vault lives inside Obsidian's iCloud container. On macOS it is just files;
    // on iOS it belongs to another app and cannot be reached. Showing workouts on the
    // phone would mean shipping the Mac's parsed result across. Not built yet.
    #if os(macOS)
    static let vault = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(Config.vaultPath ?? "")
    static var journalDir: URL { vault.appendingPathComponent("2. Daily Journal") }
    #endif

    // Session names score 3, exercise names 1. Record lines more often name exercises
    // than sessions. Bare words like 'pull' and 'push' are deliberately absent:
    // "Face pull" once pushed a push day into the pull bucket.
    private static let session: [(String, String)] = [
        ("하체A", #"하체\s*A"#), ("하체B", #"하체\s*B"#),
        ("상체당기기", #"상체[^.\n]{0,12}당기|당기기\s*우선"#),
        ("상체밀기", #"상체[^.\n]{0,12}밀|밀기"#),
        ("코어", #"코어|core"#), ("필라테스", #"필라테스|pilates"#), ("골프", #"골프|golf"#),
        ("유산소", #"zone\s*2|러닝|달리기|인터벌|4x4|스테어마스터|stairmaster"#),
        ("자세교정", #"직각어깨|자세\s*교정"#), ("휴식", #"휴식|rest\b"#),
    ]
    private static let exercise: [(String, String)] = [
        ("하체A", #"squat|스쿼트|leg\s*press|레그\s*프레스|leg\s*extension|bulgarian|불가리안"#),
        ("하체B", #"hip\s*thrust|힙\s*스러스트|rdl|루마니안|leg\s*curl|레그\s*컬|farmer\s*carry|deadlift|데드"#),
        ("상체당기기", #"\bchin|친업|풀업|pull[\s-]*up|\brow\b|로우|lat\s*pull|랫풀|face\s*pull|bicep|이두"#),
        ("상체밀기", #"bench|벤치|incline|인클라인|\bohp\b|shoulder\s*press|숄더|\bdip\b|딥스|프레스"#),
        ("코어", #"플랭크|plank|데드버그|크런치"#),
        ("자세교정", #"prone\s*y|wall\s*slide|supine\s*db"#),
    ]

    private static func has(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func count(_ text: String, _ pattern: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return 0 }
        return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    static func classify(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var score: [String: Int] = [:]
        for (name, pat) in session where has(text, pat) { score[name, default: 0] += 3 }
        for (name, pat) in exercise { score[name, default: 0] += count(text, pat) }
        score = score.filter { $0.value > 0 }
        // Drop a tag the text explicitly negates ("B, not A")
        for name in score.keys where has(text, "\(name.prefix(2))\\s*\(name.dropFirst(2))\\s*아님") {
            score[name] = nil
        }
        guard let top = score.values.max() else { return [] }
        // Golf, cardio and pilates often run alongside another session,
        // so keep them even when they score low
        return score.sorted { $0.value > $1.value }
            .filter { $0.value == top || ["골프", "유산소", "필라테스"].contains($0.key) }
            .map(\.key)
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

    /// Reads one day's journal entry and returns its workout and notes.
    static func load(_ day: Date) -> (Workout?, [JournalNote]) {
        #if !os(macOS)
        return (nil, [])
        #else
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let prefix = f.string(from: day)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: journalDir.path) else { return (nil, []) }
        // Korean filenames mix NFD and NFC, so normalise before comparing
        guard let name = names.sorted().first(where: {
            $0.precomposedStringWithCanonicalMapping.hasPrefix(prefix) && $0.hasSuffix(".md")
        }), let body = try? String(contentsOf: journalDir.appendingPathComponent(name), encoding: .utf8)
        else { return (nil, []) }

        var w = Workout()
        w.noteTitle = stripMD(String(name.precomposedStringWithCanonicalMapping.dropFirst(11).dropLast(3)))

        if let sec = firstMatch(body, #"^##\s*\*{0,2}운동[^\n]*\n(.*?)(?=^##\s|\Z)"#) {
            w.planned = firstMatch(sec, #"오늘 세션:[ \t]*(.*)"#, dotAll: false).map(stripMD) ?? ""
            // \s* after the colon would swallow newlines and capture the next heading
            w.actual = firstMatch(sec, #"^[ \t]*-[ \t]*기록[ \t]*:[ \t]*(.*(?:\n(?![ \t]*(?:[-*>#]|$)).*)*)"#, dotAll: false).map(stripMD) ?? ""
            w.plannedTags = classify(w.planned)
            let at = classify(w.actual)
            w.actualTags = at.isEmpty && !w.actual.isEmpty ? w.plannedTags : at
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
        return (w.planned.isEmpty && w.actual.isEmpty && w.postureDone.isEmpty && w.stretchDone.isEmpty ? nil : w, notes)
        #endif
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
