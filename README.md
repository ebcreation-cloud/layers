# Layers

A calendar for macOS and iOS that shows the day you planned next to the day you had.

Events from several Google accounts and an Outlook account arrive in one grid, coloured by
account. Alongside them sit the notes captured on the phone and, on the Mac, the workout
actually logged in an Obsidian journal. Editing an event writes back to its source, so a
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
  columns. Captures sit at the time they were written.
- **Editing.** Create, edit and delete. Subscribed holiday calendars are read-only and the
  editor says so. Recurring events change only the occurrence you opened.
- **Alerts** 30 minutes and 5 minutes before an event and at its start. When the event has
  a video-call link, the alert carries a Join button.
- **Life strip.** A band along the foot of each month cell showing the workout logged and
  how many notes landed that day.

## Things worth knowing before changing this

**Plan and execution are not the same thing.** The journal template injects a planned
workout into every daily note, so counting plans makes it look like a workout happened
every day. The only evidence is the record line and the checkboxes. In one sample month
that was 11 days out of 26. The workout chip has three steps of one green precisely so a
plan never reads as a result.

**Colour encodes the account and nothing else.** One account holds about two thirds of all
events, so its colour has to be the quiet one; colour marks the exception, not the rule.
The tinted box around the time carries it. A dot or a thin rule gave too little colour area
to tell three accounts apart.

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

Usage descriptions must live in `project.yml` under `info.properties`. XcodeGen overwrites
the file named by `info.path`, so a hand-written `Info.plist` is silently replaced, and iOS
refuses a permission request that has no description without reporting an error.

## Layout

```
Sources/
  LayersApp.swift          Header, account filter, month and day switching
  Model/
    Config.swift           Everything personal to one setup
    Platform.swift         The few things macOS and iOS do differently
    Theme.swift            Palette and type, defined light and dark as pairs
    CalendarData.swift     EventKit reading and writing, merging, week segments
    Journal.swift          Obsidian daily-note parsing (macOS only)
    Notifier.swift         Local notifications with meeting links
  Views/
    MonthView.swift        Week rows and the bars that cross them
    DayView.swift          Shared time axis for events and notes
    EventEditor.swift      Create, edit, delete
Icon/render.swift          Draws the app icon at every size
```
