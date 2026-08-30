import SwiftUI

struct DayView: View {
    @ObservedObject var data: CalendarData
    let day: Date
    @Binding var editor: EditorTarget?
    private let cal = Calendar.current
    private let h0 = 6, h1 = 24
    private let px: CGFloat = 44

    private var spanning: [Item] {
        data.items.filter { data.visible($0) && $0.spansDays
            && data.day($0.start) <= data.day(day) && data.day(day) <= data.day($0.end) }
    }

    var body: some View {
        let d0 = cal.startOfDay(for: day)
        let timed = data.timed(on: day)
        let w = data.workouts[d0]
        let notes = data.notes[d0] ?? []
        let jnotes = data.journalNotes[d0] ?? []

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

            // Things without a time: all-day events, the workout record, untimed notes
            HStack(alignment: .top, spacing: 0) {
                Text("ALL DAY").font(.mono(9.5)).tracking(0.8)
                    .foregroundStyle(Theme.inkFaint).frame(width: 56, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(spanning) { e in
                        HStack(spacing: 0) {
                            Rectangle().fill(e.source.color).frame(width: 2)
                            Text(e.isAllDay ? e.title : "\(Fmt.hm(e.start)) \(e.title)")
                                .font(.ui(11, .medium))
                                .foregroundStyle(e.source.color).padding(.horizontal, 6).padding(.vertical, 1)
                            Spacer(minLength: 0)
                        }
                        .frame(height: 16)
                        .background(e.source.color.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    if spanning.isEmpty { Text("—").font(.ui(11)).foregroundStyle(Theme.inkFaint) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    if let w, let chip = w.chip { WorkoutCard(w: w, chip: chip) }
                    // Finished todos pile up six deep on a busy day. Rather than stacking cards
                    // vertically, run the contents sideways under one label.
                    ForEach(grouped(jnotes, exceptOf: notes), id: \.0) { label, texts in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(label.uppercased()).font(.mono(9)).tracking(0.7)
                                .foregroundStyle(Theme.inkFaint)
                            FlowText(items: texts)
                        }
                    }
                    ForEach(notes.filter(\.isDue)) { n in
                        HStack(spacing: 0) {
                            Rectangle().fill(Theme.due).frame(width: 2.5)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("DUE").font(.mono(9)).tracking(0.7).foregroundStyle(Theme.due)
                                Text(n.text).font(.ui(11.5)).foregroundStyle(Theme.ink)
                            }.padding(.horizontal, 8).padding(.vertical, 5)
                            Spacer(minLength: 0)
                        }
                        .background(Theme.due.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxHeight: 92)   // about four rows
            .background(Theme.sunk.opacity(0.55))
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
                            ForEach(laidOut) { l in
                                EventBlock(item: l.item)
                                    .hoverable(radius: 5, tint: l.item.source.color)
                                    .onTapGesture { editor = .edit(l.item) }
                                    .frame(width: geo.size.width / CGFloat(l.cols) - 6,
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

private struct EventBlock: View {
    let item: Item
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(item.source.color).frame(width: 2.5)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(Fmt.hm(item.start)).font(.mono(9.5)).foregroundStyle(Theme.inkDim)
                Text(item.title).font(.ui(11.5, .medium))
                    .foregroundStyle(Theme.ink).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(item.source.color.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 5))
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

private struct WorkoutCard: View {
    let w: Workout
    let chip: (level: Workout.Level, tags: [String])
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach(chip.tags, id: \.self) { t in
                    Text(Workout.label(t)).font(.ui(10.5, .medium))
                        .foregroundStyle(Theme.workout).padding(.horizontal, 7).padding(.vertical, 1.5)
                        .background(Theme.workout.opacity(chip.level == .done ? 0.16 : 0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            if !w.actual.isEmpty {
                Text(w.actual).font(.ui(11.5)).foregroundStyle(Theme.ink)
            }
            if let r = w.recovery {
                Text("Recovery \(r)%").font(.ui(10.5)).foregroundStyle(Theme.inkFaint)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
    }
}

/// Flows items sideways. On a day with many finished todos, stacking is unmanageable.
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
