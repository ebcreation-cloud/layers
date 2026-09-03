import SwiftUI

/// Height of the all-day band's content, read from its background so that asking for
/// it does not change it.
private struct BandKey: PreferenceKey {
    static let defaultValue: CGFloat = 40
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Width of the events lane on the time axis, measured there and handed up to the
/// all-day band so the two end on the same vertical.
///
/// It cannot be derived twice from the same arithmetic. The axis scrolls and the band
/// mostly does not, so with legacy scrollers — which is what a Mac with a mouse gets —
/// the axis loses about fifteen points to a scroller the band never shows, and the
/// all-day shading ran past the rule and into the notes.
private struct LaneKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct DayView: View {
    @ObservedObject var data: CalendarData
    let day: Date
    @Binding var editor: EditorTarget?
    /// Ticks so the current-hour line moves. The view is otherwise rebuilt only on a
    /// reload, so on a day left open the line would stay where it was at breakfast.
    @State private var now = Date()
    /// Natural height of the all-day band, measured so it can be capped. See `body`.
    @State private var bandH: CGFloat = 40
    /// Width of one lane on the axis below. See `LaneKey`.
    @State private var lane: CGFloat = 0
    /// The gap the axis leaves between a block and the rule beside it. The all-day band
    /// leaves the same one, or the two shadings stop on different verticals.
    private let gutter: CGFloat = 6
    private let cal = Calendar.current
    private let h0 = 6, h1 = 24
    private let px: CGFloat = 44
    /// How much the all-day band may take before it starts scrolling. A workout card
    /// with its record line is about 150pt on its own, so the Mac gives it room to
    /// stand beside the notes rather than half covering them.
    private var bandMax: CGFloat { isPhone ? 92 : 176 }

    private var spanning: [Item] {
        data.items.filter { data.visible($0) && $0.spansDays
            && data.day($0.start) <= data.day(day) && data.day(day) <= data.day($0.end) }
    }

    var body: some View {
        let w = data.workouts[cal.startOfDay(for: day)]

        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(Fmt.md(day)).font(.mono(26, .semibold))
                Text(Fmt.weekday(day)).font(.ui(13)).foregroundStyle(Theme.inkDim)
                Spacer()
                if let t = w?.noteTitle, !t.isEmpty {
                    Text(t).font(.ui(12.5)).foregroundStyle(Theme.inkFaint)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            Divider().overlay(Theme.line)

            HStack(spacing: 0) {
                Text("TIME").frame(width: 56, alignment: .leading)
                Text("EVENTS").frame(maxWidth: .infinity, alignment: .leading)
                Text("NOTES").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.mono(9.5)).tracking(0.9).foregroundStyle(Theme.inkFaint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.sunk)
            Divider().overlay(Theme.line)

            // Things without a time: all-day events, the workout record, untimed notes.
            //
            // maxHeight was the wrong tool twice over. It does not clip, so on a day
            // with a workout card and six finished todos the band drew over the column
            // heads above and the hours below; and it stretches, so a quiet day left a
            // band of empty grey. The height is measured and then capped, and what does
            // not fit scrolls.
            ScrollView {
                allDay.background { GeometryReader { g in
                    Color.clear.preference(key: BandKey.self, value: g.size.height) } }
            }
            .frame(height: min(bandH, bandMax))
            .background(Theme.sunk.opacity(0.55))
            .onPreferenceChange(BandKey.self) { bandH = $0 }
            Divider().overlay(Theme.line)

            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(h0..<h1, id: \.self) { h in
                            Text(String(format: "%02d:00", h))
                                .font(.mono(10)).foregroundStyle(Theme.inkFaint)
                                .frame(height: px, alignment: .top)
                        }
                    }.frame(width: 56)

                    axisColumn {
                        // Overlapping events split sideways. Width is needed, so it is measured here only.
                        GeometryReader { geo in
                            Color.clear.preference(key: LaneKey.self, value: geo.size.width)
                            // An empty slot is a place to put something. Under the blocks,
                            // so a tap on an event still opens the event, and it costs
                            // nothing to be wrong: what opens is an editor with a Cancel.
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { p in editor = .createAt(slot(at: p.y)) }
                            // The current hour. The one place colour lands on the axis,
                            // and only on the day it means something.
                            if cal.isDateInToday(day) {
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Theme.accent).frame(height: 1.5)
                                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                                        .offset(x: -3.5)
                                }
                                .offset(y: y(now) - 0.75)
                                .allowsHitTesting(false)
                            }
                            ForEach(laidOut) { l in
                                EventBlock(item: l.item)
                                    .hoverable(radius: 5)
                                    .onTapGesture { editor = .edit(l.item) }
                                    .frame(width: geo.size.width / CGFloat(l.cols) - gutter,
                                           height: max(18, blockH(l.item)))
                                    .offset(x: geo.size.width / CGFloat(l.cols) * CGFloat(l.col),
                                            y: y(l.item.start))
                            }
                        }
                    }

                    Rectangle().fill(Theme.lineSoft).frame(width: 1)

                    // Captures sit at their creation time: that is when the thought arrived.
                    axisColumn {
                        ForEach(stackedNotes) { p in
                            NoteCard(note: p.note).offset(y: p.top)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
        .onPreferenceChange(LaneKey.self) { lane = $0 }
        .task {
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// The time a click on the axis means. Rounded to the half hour: a click is a rough
    /// gesture and 07:23 is never what anyone was aiming at.
    private func slot(at yy: CGFloat) -> Date {
        let hours = Double(h0) + Double(yy / px)
        let half = (hours * 2).rounded(.down) / 2
        let clamped = min(max(half, Double(h0)), Double(h1) - 0.5)
        return cal.date(bySettingHour: Int(clamped), minute: clamped.truncatingRemainder(dividingBy: 1) > 0 ? 30 : 0,
                        second: 0, of: day) ?? day
    }

    /// All-day events on the left, and on the right what the journal recorded: the
    /// workout, the todos finished, anything due. None of it belongs on the time axis.
    private var allDay: some View {
        let d0 = cal.startOfDay(for: day)
        let w = data.workouts[d0]
        let notes = data.notes[d0] ?? []
        let jnotes = data.journalNotes[d0] ?? []
        return HStack(alignment: .top, spacing: 0) {
            Text("ALL DAY").font(.mono(9.5)).tracking(0.8)
                .foregroundStyle(Theme.inkFaint).frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                // All-day and multi-day events open the same editor as a timed block.
                // Without this they are the one kind of event that cannot be moved.
                ForEach(spanning) { e in
                    HStack(spacing: 0) {
                        Text(e.isAllDay ? e.title : "\(Fmt.hm(e.start)) \(e.title)")
                            .font(.mono(9.5)).tracking(0.7).textCase(.uppercase)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1).truncationMode(.tail)
                            .padding(.horizontal, 6)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 17)
                    .overlay(OutlineBox())
                    .hoverable(radius: 2)
                    .onTapGesture { editor = .edit(e) }
                }
                if spanning.isEmpty { Text("—").font(.ui(11)).foregroundStyle(Theme.inkFaint) }
            }
            // The same lane, and the same gap before the rule, as the axis below.
            .padding(.trailing, gutter)
            .frame(maxWidth: lane > 0 ? lane : .infinity, alignment: .leading)
            // Where the rule stands on the axis. Kept clear here: a rule through the
            // band would read as a table the rest of the view is not.
            Color.clear.frame(width: 1)
            VStack(alignment: .leading, spacing: 5) {
                if let w, let tags = w.chip { WorkoutCard(w: w, tags: tags) }
                // Finished todos pile up six deep on a busy day. Rather than stacking cards
                // vertically, run the contents sideways under one label.
                ForEach(grouped(jnotes, exceptOf: notes), id: \.0) { label, texts in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(label.uppercased()).font(.mono(9)).tracking(0.7)
                            .foregroundStyle(Theme.inkFaint)
                        FlowText(items: texts)
                    }
                }
                // A deadline takes the same colour as today. The exclamation is what
                // keeps them apart — a hue can only say "look here", and both of these
                // mean it; only the mark says which kind of looking is wanted.
                ForEach(notes.filter(\.isDue)) { n in
                    HStack(alignment: .top, spacing: 7) {
                        Text("!").font(.mono(9, .bold))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(RoundedRectangle(cornerRadius: 2).fill(Theme.accent))
                        Text(n.text).font(.ui(11.5)).foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    /// Groups reminders and journal notes by label. A script copies reminders into the
    /// journal, so the same text arrives twice; normalise and show it once.
    private func grouped(_ jnotes: [JournalNote], exceptOf axis: [Note]) -> [(String, [String])] {
        func key(_ t: String) -> String { String(t.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(30)) }
        var seen = Set(axis.filter { !$0.isDue }.map { key($0.text) })
        var order: [String] = []
        var out: [String: [String]] = [:]
        for n in jnotes {
            let k = key(n.text)
            guard !k.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k)
            if out[n.label] == nil { order.append(n.label) }
            out[n.label, default: []].append(n.text)
        }
        return order.map { ($0, out[$0] ?? []) }
    }

    @ViewBuilder
    private func axisColumn<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(h0..<h1, id: \.self) { _ in
                    Rectangle().fill(Theme.lineSoft).frame(height: 1)
                    Spacer(minLength: 0)
                }
            }.frame(height: CGFloat(h1 - h0) * px)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: CGFloat(h1 - h0) * px)
    }

    struct Placed: Identifiable { let id = UUID(); let note: Note; let top: CGFloat }
    struct Laid: Identifiable { let id = UUID(); let item: Item; let col: Int; let cols: Int }

    /// Finds clusters of overlapping events and splits columns within each cluster only,
    /// so events outside a cluster keep full width.
    private var laidOut: [Laid] {
        let list = data.timed(on: day).sorted { $0.start < $1.start }
        var groups: [[Item]] = [], cur: [Item] = [], curEnd = Date.distantPast
        for e in list {
            if !cur.isEmpty, e.start >= curEnd { groups.append(cur); cur = [] }
            cur.append(e); curEnd = max(curEnd, e.end)
        }
        if !cur.isEmpty { groups.append(cur) }
        var out: [Laid] = []
        for g in groups {
            var colEnd: [Date] = [], assign: [Int] = []
            for e in g {
                if let i = colEnd.firstIndex(where: { $0 <= e.start }) { colEnd[i] = e.end; assign.append(i) }
                else { colEnd.append(e.end); assign.append(colEnd.count - 1) }
            }
            for (e, c) in zip(g, assign) { out.append(Laid(item: e, col: c, cols: colEnd.count)) }
        }
        return out
    }

    /// Notes crowded into the same slot are pushed down so they do not overlap.
    private var stackedNotes: [Placed] {
        let d0 = cal.startOfDay(for: day)
        let list = (data.notes[d0] ?? []).filter { !$0.isDue && $0.at != nil }
            .sorted { $0.at! < $1.at! }
        var out: [Placed] = []
        var bottom: CGFloat = -1000
        for n in list {
            let want = y(n.at!)
            let top = max(want, bottom + 4)
            out.append(Placed(note: n, top: top))
            // Height is estimated from text length; measuring exactly needs a second layout pass.
            bottom = top + 26 + CGFloat(max(0, (n.text.count - 22) / 22)) * 14
        }
        return out
    }

    private func y(_ d: Date) -> CGFloat {
        let m = Double(cal.component(.hour, from: d) * 60 + cal.component(.minute, from: d))
        return CGFloat(m / 60 - Double(h0)) * px
    }
    private func blockH(_ e: Item) -> CGFloat {
        CGFloat(max(24, e.end.timeIntervalSince(e.start) / 60) / 60) * px - 3
    }
}

/// A block on the time axis. The fill is neutral now and the time chip carries the
/// account, so a column of events reads as one material with four kinds of time in it.
private struct EventBlock: View {
    let item: Item
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            TimeChip(text: Fmt.hm(item.start), source: item.source, size: 9)
            Text(item.title).font(.ui(11.5))
                .foregroundStyle(Theme.ink).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.ink.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// The workout record, expanded. Same rounded outline as the month chip, so the two
/// read as the same kind of thing at two sizes.
private struct WorkoutCard: View {
    let w: Workout
    let tags: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(tags, id: \.self) { t in
                    Text(Workout.label(t))
                        .font(.mono(9.5)).tracking(0.5).textCase(.uppercase)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 8).frame(height: 17)
                        .overlay(OutlineBox(rounded: true))
                }
            }
            if !w.actual.isEmpty {
                Text(w.actual).font(.ui(11.5)).foregroundStyle(Theme.ink)
            }
            if let r = w.recovery {
                Text("Recovery \(r)%").font(.ui(10.5)).foregroundStyle(Theme.inkFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NoteCard: View {
    let note: Note
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(note.label.uppercased()).font(.mono(9)).tracking(0.7).foregroundStyle(Theme.inkFaint)
                if let t = note.time {
                    Text(t).font(.mono(9.5)).foregroundStyle(Theme.inkFaint)
                }
            }
            Text(note.text).font(.ui(11.5)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
        .padding(.trailing, 6)
    }
}


private struct FlowText: View {
    let items: [String]
    var body: some View {
        Text(items.joined(separator: "   ·   "))
            .font(.ui(11)).foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Fmt {
    static let mdF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "M.dd"; return f }()
    static let wdF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE"; f.locale = Locale(identifier: "en_US"); return f }()
    static func md(_ d: Date) -> String { mdF.string(from: d) }
    static func weekday(_ d: Date) -> String { wdF.string(from: d) }
}
