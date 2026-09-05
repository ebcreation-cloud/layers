# Layers

A calendar for macOS and iOS that shows the day you planned next to the day you had.

Events from several Google accounts and an Outlook account arrive in one grid, coloured by
account. Alongside them sit the notes captured on the phone and the workout actually
logged in an Obsidian journal, which both devices read. Editing an event writes back to its source, so a
change here shows up in Google Calendar or Outlook.

Built for one person's setup. The parts that are personal are isolated in
[`Sources/Model/Config.swift`](Sources/Model/Config.swift).

## Why EventKit and not the Google and Microsoft APIs

Add the accounts once in **System Settings → Internet Accounts** (macOS) or
**Settings → Apps → Calendar → Accounts** (iOS), and EventKit exposes every calendar,
including reminders, with read *and* write access that syncs back over CalDAV and Exchange.

No OAuth client, no token refresh, no sync tokens, no API quota, and it works offline.
Direct API integration would have been several times the code for less.

The two devices are separate: adding accounts on the Mac does nothing for the phone.

## What it does

- **Month view.** One week is one layer; multi-day events run across it as a single bar,
  clipped at week edges. Every week is the same height, and the number of events shown
  adapts to what the bars leave behind.
- **Day view.** Events and notes share one time axis. Overlapping events split into
  columns. Captures sit at the time they were written, and the current hour is a red rule
  across the axis. Clicking an empty slot starts an event there, rounded to the half hour.
- **Editing.** Create, edit and delete, with a location and — on a new event — a repeat.
  Subscribed holiday calendars are read-only and the editor says so. Recurring events
  change only the occurrence you opened, and the editor says that too.
- **Paging.** On the phone, a sideways swipe steps a month in the month view and a day in
  the day view, and the new page slides in from the side the swipe came from. On the Mac
  it is the ‹ › buttons and the arrow keys.
- **Alerts** 30 minutes and 5 minutes before an event and at its start. On the Mac the
  alert is a window Layers raises itself, top right, above full-screen apps and on every
  Space, carrying a Join button when the event has a video-call link. The half-hour
  warning clears itself; the two after it stay until they are answered.
- **Life strip.** A band along the foot of each month cell showing the workout actually
  recorded — plans and rest days are not shown — and how many notes landed that day. The
  tag on it is whatever the journal's record line was tagged with, as written.
- **Refreshing.** The grid follows the local store as it changes, and catches up on its
  own every ten minutes on the Mac and on every return to the app on the phone. By hand
  it is ⌘R, or a pull down on the phone.
- **Menu bar (macOS).** Layers stays resident, so closing the window does not end the
  alerts. The item names the next event and counts down to it, but only inside the last
  hour, and carries Join for a call.

## Things worth knowing before changing this

**Plan and execution are not the same thing.** The journal template injects a planned
workout into every daily note, so counting plans makes it look like a workout happened
every day. The only evidence is the record line and the checkboxes. In one sample month
that was 11 days out of 26. The workout chip has three steps of one green precisely so a
plan never reads as a result.

**The record line names its own session, and nothing else may name it.** Reading the
session off the exercise names was only ever a guess, and the guess was wrong in both
directions. 25 August was a Lower B day logged as "bulgarian split squat", which reads as
Lower A and was tagged as one. 3 September was logged as "swimming, yoga", which matched
no vocabulary at all and showed as a bare "workout". A fixed list of session names can
only recognise the sessions somebody thought of in advance.

So there is no vocabulary and no classifier. Whatever is written at the head of the
record line *is* the tag, as written:

    - 기록: Leg B, Core - RDL 원판 12.5kg 3x10. 허리 중립 잘 지켰다
    - 기록: swimming, yoga
    - 기록: Lower A
        - leg extension 27.5kg (12, 12, 12)

Everything up to the first ` - ` or ` | ` is tags, split on `,` `/` `+`. A line with no
separator is all tags. Detail goes after the separator, or on the indented bullets under
the line, which the record regex already leaves out. Only the separator has to be spaced,
because a bare hyphen is part of words that turn up in tags ("push-up", "T-spine").

Two guards, and only two. A piece carrying a digit or running past twenty characters is
not a tag but the start of the note, so a day written without a separator becomes a
record with no name rather than one enormous name — that is what the older notes here do,
and they read as a plain "workout", which is exactly what they are: recorded, unnamed.
And a tag that says rest is still read rather than repeated, because it decides whether
there is a chip at all.

Nothing falls back to the planned session any more. The template injects a plan into
every note, and borrowing it whenever the record was unrecognisable is how a day of
swimming came to be filed as the leg session nobody did.

**Rest is not a workout.** A day recorded as rest was recorded, so it is not a plan; but
nothing was done, so it gets no chip. It used to get one in grey, on the argument that
being recorded made it worth a mark, and a blank day turned out to say it more plainly.
This is the one place a tag is interpreted instead of repeated: "오늘 그냥 쉬었어" is a
whole record line, and so a whole tag, and a rest day drawn as a workout is the single
thing this calendar must not do.

**The two halves of the day view cannot compute their own width.** The all-day band and
the time axis each split the space into an events lane and a notes lane, but the axis
scrolls and the band mostly does not — so on a Mac with a mouse, which gets legacy
scrollers, the axis quietly loses about fifteen points to a scroller the band never shows.
Deriving the lane twice from the same arithmetic put the all-day shading past the rule and
into the notes. The axis measures its lane and the band is told.

**Deleting one occurrence used to delete the wrong one.** Every occurrence of a
recurring event shares one `eventIdentifier` — that is simply how EventKit names them —
so asking the store for "the event with this identifier" does not name the Saturday that
was open, only the series. Which occurrence comes back is EventKit's choice, usually the
series' first, so a delete aimed at 3 October could remove a Saturday months earlier
instead and leave the one you opened sitting there untouched. It looked like the delete
had silently failed, because in the one place that mattered, it had: the day on screen
was still there.

`occurrence(_:)` is the fix: a predicate for the minute around `item.start`, matched
against the identifier, can only return the instance actually on screen. `save` and
`delete` both go through it now instead of asking for the identifier alone.

**A repeat belongs to a series, not to a day.** The editor saves one occurrence, on
purpose, so it offers a repeat only when creating and never when editing — otherwise
changing "every week" on a Tuesday would mean something nobody could predict. On an event
that already repeats it says so instead, because moving one occurrence of a weekly meeting
should not feel like moving the meeting.

**An alert outlives the window that scheduled it.** That is the whole reason for the
menu bar item: without it, closing the calendar took every pending alert with it. Three
things follow. The scene is a `Window` rather than a `WindowGroup`, because only a scene
with a fixed id can be reopened by name once it has been closed, and reopening has to
cope with both a closed window and a merely hidden one. `CalendarData` is shared, since
the window is no longer the only thing reading the calendar and two `EKEventStore`s would
mean two permission prompts. And the reload that used to ride on the window now has a
beat of its own — ten minutes, plus `EKEventStoreChanged` — or an event added on the
phone this afternoon would never raise anything.

**A system banner is the wrong shape for a meeting alert.** It is muted outright while
the display sleeps — the system logs `muted by display state` and files it under
Notification Center with no banner and no sound — it goes after five seconds, it does not
survive a Focus, and it never draws over a full-screen app, which is where you are when a
call is about to start. So on the Mac the alert is Layers' own panel at `.screenSaver`
level, and the scheduled notification stays only as the fallback for a quit app,
withdrawn one alert at a time as the panel takes each one over. Two AppKit details decide
whether it works at all: a borderless panel cannot become key, and a click on a window
belonging to an inactive app is spent bringing that window forward unless the content
view accepts first mouse. Miss either and Join is dead. `-testAlert` raises a sample
without waiting for a real meeting.

**Alerts must not be read off the month on screen.** `items` holds whichever month you
are looking at, so building the alerts from it meant paging forward to check something
cancelled every alert for this week and scheduled none, silently. The alerts come from
their own read of the coming seven days. Two other things made them look broken when they
were not: `add` is refused while the permission prompt is still outstanding, so the first
run scheduled nothing, and the two early alerts carried no sound, which on a Mac is five
seconds of movement at the edge of a screen you were not looking at. A sleeping display
mutes them regardless — the system logs `muted by display state` and files them under
Notification Center with no banner and no sound.

**One colour, and it is not the account's.** The page is paper and ink: a warm off-white
ground, warm near-black type, hairline rules, and no hue anywhere except a single
fluorescent red. That red appears in exactly four places — today, the current hour, a
deadline, and delete — and nothing else may take it. A page with one colour on it points
at something; a page with three decorates. Deadline and delete share the value with today
on purpose, and are told apart by a mark rather than a hue: a deadline carries an
exclamation, and delete is a button you had to open an editor to reach.

**The phone puts the density on the title, not the time.** A phone month cell is about
55pt wide, which is not enough for a time and a title side by side, and the title is the
half worth keeping. So on the phone the time is dropped and the account's density sits
behind the title itself — the same four states, on the only thing there is room for.
`-phone` forces the phone layout on the Mac, because it is the one layout that cannot be
checked where the real calendar is: the simulator has no events in it.

**The account moved from hue to density.** Colour used to encode the account and nothing
else. With the hue gone the same job is done by how much ink the time chip holds — none,
a fourteen-percent tint, solid, or an outline — because that chip was already the thing
carrying it. A dot or a thin rule had been tried and gave too little area to tell three
accounts apart, let alone four. Personal is about two thirds of all events and so holds
no ink at all: density marks the exception, not the rule, exactly as colour used to. The
account filter is its own legend — each account's name is set in that account's density,
so there is no key to learn.

**The all-day bar was the cliché, and it was a shape, not a colour.** A pale tinted pill
with rounded corners filling the cell width is what Google, Apple and Notion all draw, so
no palette could get out from under it. It is an outline now: square, unfilled, and
carrying no account, because which account a holiday or a payment arrived in is the one
thing nobody looks up. Three stacked on one day stay three lines instead of becoming a
grey slab. The workout record is also an outlined box, so it is rounded where the all-day
bar is square — an event is a span and has ends, a record is a single fact and has none.
Without that the two read as the same mark on any day with no all-day event.

**The month grid lost its vertical rules.** Only the week rules remain, which makes the
month read as ruled paper rather than as a table. Nothing separates Tuesday from Wednesday
but the day number, and that turns out to be enough. Cell width is therefore
`size.width / 7` with no gap arithmetic; the span bars are offset the same way.

**Everything in the grid is set at regular weight.** Medium was carrying emphasis back
when colour marked the account and the type had to hold its own beside it. On a page of
hairlines and outlines the same weight reads as heavy, and there is nothing left for it
to compete with.

**Today is a mark, not a field.** The cell used to invert whole, which was right on paper
and floodlit one cell of a quiet page in dark. It is now a fluorescent block behind the
day number plus a 2pt rule across the top of the cell — the rule is what makes today
findable while scanning a week rather than only when the eye lands on the number.

**The phone reads the journal through a folder it was handed.** The vault lives in
Obsidian's iCloud container, and iOS gives no path into another app's container. What it
does give is a folder somebody points at: a document picker returns a security-scoped
URL, a bookmark keeps it across launches, and from there it is the same parser reading
the same notes as the Mac. `Journal` has no macOS-only code in it for that reason. It is
handed a directory.

This needs no iCloud entitlement, which is the point of doing it this way. An entitlement
means a paid developer account, and CloudKit or the key-value store would have meant one
for what is, in the end, reading some markdown.

Two things follow that the Mac never had to care about. A note iCloud has not brought
down yet is listed under a name of its own, `.2026-09-04.md.icloud`, standing where the
file will be; asking for it directly fails, and coordinating the read is what triggers
the download and waits for it. And that read blocks, so parsing moved off the main
thread: a window is seventy-five notes, and on the phone each one is a round trip to
another app's file provider. Parsed notes are kept and thrown away by modification date
and size, or a page turn would pay for the whole month again.

**Until the folder is picked, the Mac posts the phone a copy.** The record travels the
way everything else in this app already travels: the Mac writes one all-day event per
recorded day into a Google calendar of its own — tags as the title, the record line as
the notes — and the phone reads that calendar. `CalendarData.isWorkoutFeed` keeps those
events out of the grid entirely, and the calendar is hidden from the editor's picker so
nothing can be created there by hand.

It is a copy, not a sync, and it is second best on purpose. It only knows what the Mac
last exported, so a workout written on the phone this evening waits for the Mac to wake;
only what the chip shows survives the trip; and it writes into a real calendar, which
means reconciling. The journal is the truth, so a day whose record changed is rewritten
and a day whose record went away is deleted — safe only because nothing else writes
there, and correct only while the journal can be read at all. An unreachable vault parses
as no workouts, which would otherwise empty the feed and take the phone's history with
it, so publishing is skipped unless the folder is actually there.

The phone prefers the vault whenever it has one and falls back to the feed when it does
not. Both produce the same `[Date: Workout]`, which is what let the second be built
before the first. Setting `Config.workoutFeed` to nil turns the copying off for good.

**A page turn must not read the calendar.** It used to, and it cost about four hundred
milliseconds of main thread every time. Where it went was worth measuring rather than
guessing, and the answer was not where it looked: two thirds of it was refetching the
reminder list, which has no window at all. Whatever month is on screen, the whole
Pinboard is read, so reading it again on a page turn was three hundred milliseconds
spent arriving at the same answer. It is read once now, and again only when something
says the store changed.

The rest followed from the same mistake. The window read is now several months wider
than the month shown, and a load whose window is already covered returns without doing
anything, so two page turns in three do no work at all. Rebuilding the alerts hangs off
a load that actually read something rather than off the view appearing, so paging no
longer reschedules every pending notification. And the grid's questions are answered
from an index built once per change instead of by filtering: a cell used to scan the
whole window to find its own day and a week row to find its own bars, which is
forty-eight passes over several hundred events on every redraw.

What is left of a real load is about seventy milliseconds, most of it the journal, which
is parsed off the main thread. `loads` and `ms` in the status dump are how this stays
honest: the claim is that paging does no work, and there is otherwise no way to see it
from outside.

**A number can crowd out the tag it sits beside.** The life strip's note count and the
workout chip share one row, and on a phone cell — about 55pt wide — there was not room
for both. The tag was the one made to give way, so on a busy day the count ended up
sitting exactly where the tag should have read, which looks like the tag went missing
rather than like two things ran out of room. The count is dropped on the phone
entirely: it was never anything but "how many notes landed", and the tag is the one
thing on that row worth protecting.

**Nothing in a month cell may claim a width of its own.** The seven cells are equal
because each of them can shrink to nothing. One `fixedSize` on the workout chip was
enough to break it — the row has to honour a minimum it cannot shrink past, and it takes
the space from the neighbouring days, so the week visibly stopped being a grid. It was
invisible for as long as the tags came from a fixed vocabulary and every one of them was
short.

**Refreshing is three different questions.** EventKit reads a local store; the pull from
Google and Outlook is the OS's account sync, and `refreshSourcesIfNecessary` is the only
nudge a third-party app is given — a request, not a guarantee. So a refresh that finds
nothing new is not necessarily a refresh that failed.

`EKEventStoreChanged` is the only notice that a sync landed. It used to feed the alert
queue alone, so the grid learned about an event added on the phone whenever you happened
to page away and back. It now reloads the grid too, debounced by two seconds because
EventKit sends them in bursts and because publishing the workout feed causes one itself.

The journal is a folder and sends nothing at all, which is what the Mac's ten-minute beat
is for. On the phone that beat is returning to the app: iOS suspends rather than closes,
so a calendar left open yesterday shows yesterday until something asks it to look again.
By hand it is ⌘R on the Mac, and on the phone a pull — `.refreshable` on the day view,
which has a scroller, and a plain vertical drag on the month, which does not.
**The same event arrives more than once.** Public holidays come from four subscribed
calendars, so a national holiday appears three times over. Worse, one event entered into
two accounts can carry two different titles. Merging needs same day, same time and a shared
meaningful word, with common words ("payment", "birthday") excluded so two unrelated
payments on one day stay separate.

**A reminder has three dates and they mean different things.** The completion date is when
a script processed it. The due date may be a real deadline or just a copy of the capture
time. The creation date is when the thought actually arrived, and that is the one to place
on the calendar.

**Multi-day is not the same as all-day.** In one real month, four of seven multi-day events
had a start time, one beginning at 23:00. The test for drawing a bar is whether it crosses
a day boundary.

## Building

Both palettes can be seen with real data without changing the whole Mac's appearance:
`open -n Layers.app --args -light` and `-dark`.

**macOS, without Xcode.** The Command Line Tools ship the macOS SDK, so SwiftUI and
EventKit compile directly:

```sh
./build.sh && open Layers.app
```

The script signs with a self-signed certificate named `Layers Dev` in the login keychain.
This matters: an ad-hoc signature has a designated requirement of `cdhash`, which changes
on every build, so macOS treats each build as a new app and asks for calendar access again.
Signing with a certificate makes the requirement `identifier and certificate root`, which
stays put. Trust settings are not involved.

**iOS.** Needs Xcode. The project file is generated, so install
[XcodeGen](https://github.com/yonaskolb/XcodeGen) and run:

```sh
xcodegen generate
open Layers.xcodeproj
```

Set your own `DEVELOPMENT_TEAM` in `project.yml` and pick a bundle identifier nobody else
is using. On a free Apple ID the app expires after seven days and must be reinstalled.

Two things that block a first device build and say so unhelpfully: a free team cannot
create a provisioning profile until a real device is registered, and the device needs
**Developer Mode** enabled in Settings → Privacy & Security.

On the phone, open the filter sheet once and point **Journal** at the Obsidian vault in
the Files app. Until that is done the workouts come from the calendar the Mac publishes,
and if that calendar does not exist either, the phone simply shows no workouts: nothing
else depends on it.

Usage descriptions must live in `project.yml` under `info.properties`. XcodeGen overwrites
the file named by `info.path`, so a hand-written `Info.plist` is silently replaced, and iOS
refuses a permission request that has no description without reporting an error.

## Layout

```
Sources/
  LayersApp.swift          Header, account filter, month and day switching
  Model/
    Config.swift           Everything personal to one setup
    Vault.swift            The journal folder, on the phone (iOS only)
    Platform.swift         The few things macOS and iOS do differently
    Theme.swift            Palette and type, defined light and dark as pairs
    CalendarData.swift     EventKit reading and writing, merging, week segments
    Journal.swift          Obsidian daily-note parsing
    Notifier.swift         Local notifications with meeting links
  Views/
    MonthView.swift    Week rows and the bars that cross them
    DayView.swift      Shared time axis for events and notes
    EventEditor.swift  Create, edit, delete
    AlertPanel.swift   The alert window the Mac raises, and its card
    MenuBar.swift      Status item, next-event countdown, and staying resident
Icon/render.swift          Draws the app icon at every size
```

## License

MIT. See [LICENSE](LICENSE). `Config.swift` holds one person's account mapping and
journal vocabulary; nothing else in the source is specific to that setup.
