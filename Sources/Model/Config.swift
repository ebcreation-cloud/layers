import Foundation

/// Everything personal to one setup lives here, so the rest of the code stays generic.
///
/// Layers reads whatever calendars macOS and iOS already sync. It never talks to Google
/// or Microsoft itself: add the accounts in System Settings and EventKit exposes them,
/// including write access back to the source.
enum Config {

    /// Which account group a calendar belongs to. Colour encodes only this, so keep the
    /// groups few: one dominant group plus the rarer ones that deserve to stand out.
    ///
    /// Order matters. The first rule that matches wins, and the fallback is `.personal`.
    static let calendarRules: [CalendarRule] = [
        CalendarRule(.titleContains("holiday"), .holiday),
        CalendarRule(.titleIs("eunbi.creation@gmail.com"), .coaching),
        CalendarRule(.isExchange, .work),
    ]

    /// Reminder lists that belong on the calendar, keyed by day.
    ///
    /// Only capture lists belong here. Lists that act as backlogs (books to read, songs,
    /// recipes to try) have no meaningful date and would scatter noise across the month.
    static let noteLists: Set<String> = ["Pinboard"]

    /// Obsidian vault holding the daily journal, or nil to skip journal parsing.
    /// macOS only: on iOS the vault sits in another app's iCloud container.
    static var vaultPath: String? {
        "Library/Mobile Documents/iCloud~md~obsidian/Documents/Amethyst"
    }

    /// Section headings inside a daily note.
    static let workoutHeading = "운동"          // "workout"
    static let pinboardHeading = "핀보드"        // "pinboard"
    static let todoHeading = "Todo list"

    /// Minutes before an event to raise an alert. Zero means the start itself.
    static let alertOffsets = [30, 5, 0]

    /// Hosts treated as a video call, so the event gets a Join button.
    static let meetingHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com",
                               "teams.live.com", "whereby.com", "webex.com",
                               "meet.jit.si", "around.co"]

    /// Words too common to prove two events are the same. Without this, two unrelated
    /// payments on one day would merge into one.
    static let genericWords: Set<String> = ["payment", "birthday", "생일", "송금", "lunch",
        "dinner", "breakfast", "coffee", "call", "meeting", "class", "holiday",
        "observed", "day", "off", "with", "and", "the", "for"]
}

struct CalendarRule {
    enum Match {
        case titleIs(String)
        case titleContains(String)
        case isExchange
    }
    let match: Match
    let group: Source
    init(_ match: Match, _ group: Source) { self.match = match; self.group = group }
}
