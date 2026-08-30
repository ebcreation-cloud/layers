# Prototype and extraction tooling

The design was settled here before any Swift was written. A single HTML page, fed real
calendar and journal data, made the layout decisions cheap to argue about: what a month
cell can hold, how a multi-day event should look, which colour belongs to which account.

The page is still useful as a fast way to try a layout idea without rebuilding an app.

## Pieces

| | |
|---|---|
| `bridge/main.swift` | Pulls EventKit and Photos data out of macOS as JSON |
| `workout_parse.py` | Parses workouts from Obsidian daily notes |
| `build_data.py` | Joins the two into `data.json` |
| `template.html` | The page. `__DATA__` is replaced with the JSON at build time |
| `refresh.py` | Runs all of it and writes `calendar.html` |

```sh
cd bridge && ./build.sh     # once
python3 refresh.py          # extract, assemble, render
python3 refresh.py --no-extract   # re-render from data already pulled
```

## CalendarBridge must run as an app bundle

macOS attributes a permission request from a command-line process to its responsible
parent, usually the terminal or the editor that spawned it. That parent has no usage
description for calendars, so the request fails with no dialog and no error: the app simply
sees nothing. Wrapping the binary in a `.app` and launching it with `open -a` fixes it.

`open` gives no stdout, so every mode writes its result to a file the caller polls for.

## Not committed

`ek.json`, `data.json` and the rendered `calendar.html` hold real events, reminders and
notes. They stay out of version control; `refresh.py` regenerates them.
