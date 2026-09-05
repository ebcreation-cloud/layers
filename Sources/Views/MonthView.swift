import SwiftUI

// One event line. An all-day bar and a timed row share these, so within a cell every
// event has the same height, the same font, the same left edge and the same gap to the
// next one. Two sets of numbers made a week read as two lists that happened to touch.
private let evH: CGFloat = isPhone ? 13 : 16
private let evFont: CGFloat = isPhone ? 9.5 : 10.5
private let laneH: CGFloat = evH + 1
/// Gap from the cell edge to an event, all-day bar or timed row alike.
private let evInset: CGFloat = 3
private let headH: CGFloat = 24
// Week height follows the window. Pinning it meant a six-week month overflowed a 13"
// screen and the last row hid behind the Dock. Every week still shares one height,
// because they all shrink together.
private let rowMinH: CGFloat = 78
private let stripH: CGFloat = 26

struct MonthView: View {
    @ObservedObject var data: CalendarData
    @Binding var cursor: Date
    @Binding var selected: Date?
    private let cal = Calendar.current
    private let dow = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private var weeks: [[Date]] {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: cursor))!
        let start = cal.date(byAdding: .day, value: -(cal.component(.weekday, from: first) - 1), to: first)!
        let n = cal.range(of: .day, in: .month, for: first)!.count
        let rows = Int(ceil(Double(cal.component(.weekday, from: first) - 1 + n) / 7))
        return (0..<rows).map { r in (0..<7).map { c in cal.date(byAdding: .day, value: r * 7 + c, to: start)! } }
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 1) {
                ForEach(dow, id: \.self) { d in
                    Text(d.uppercased())
                        .font(.mono(10)).tracking(1)
                        .foregroundStyle(Theme.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 3)
                }
            }
            VStack(spacing: 1) {
                ForEach(weeks.indices, id: \.self) { i in
                    WeekRow(data: data, days: weeks[i], month: cursor, selected: $selected)
                }
            }
            .frame(maxHeight: .infinity)
            .background(Theme.line)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
            #if !os(macOS)
            // The month is a grid, not a scroller, so `.refreshable` has nothing to
            // attach to and the pull has to be read directly. Simultaneous and vertical
            // only, mirroring the sideways paging gesture: the two cannot both fire,
            // because each demands its own axis by a clear margin.
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { v in
                        let dx = v.translation.width, dy = v.translation.height
                        guard dy > 90, dy > abs(dx) * 1.6 else { return }
                        Task { await data.refresh() }
                    })
            #endif
        }
    }
}

/// Width is measured from the background. A GeometryReader there does not feed back
/// into the parent's size. Putting one in the body made the height jump after a view
/// switch, leaving a band of empty space above the grid.
private struct SizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let n = nextValue()
        value = CGSize(width: max(value.width, n.width), height: max(value.height, n.height))
    }
}

/// One week is one layer. Multi-day events run across it as a single bar.
/// Drawn per cell they can never look continuous.
private struct WeekRow: View {
    @ObservedObject var data: CalendarData
    let days: [Date]
    let month: Date
    @Binding var selected: Date?
    @State private var size: CGSize = .zero

    /// Width of one cell. The cells sit flush against each other: the grid keeps its
    /// week rules and drops the day ones, so the month reads as ruled paper rather than
    /// as a table. Nothing separates Tuesday from Wednesday but the day number.
    private var colW: CGFloat { max(0, size.width / 7) }

    var body: some View {
        let segs = data.segments(weekStart: days[0])
        let lanes = (segs.map(\.lane).max() ?? -1) + 1
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { d in
                    DayCell(data: data, day: d, month: month, lanes: lanes,
                            rowHeight: size.height, selected: $selected)
                }
            }
            .background {
                GeometryReader { g in
                    Color.clear.preference(key: SizeKey.self, value: g.size)
                }
            }
            if size.width > 0 {
                ForEach(segs) { seg in
                    let span = CGFloat(seg.endCol - seg.startCol + 1)
                    let lead: CGFloat = seg.openLeft ? 0 : evInset
                    let trail: CGFloat = seg.openRight ? 0 : evInset
                    SpanBar(seg: seg)
                        .frame(width: max(0, colW * span - lead - trail), height: evH)
                        .offset(x: colW * CGFloat(seg.startCol) + lead,
                                y: headH + CGFloat(seg.lane) * laneH)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: rowMinH, maxHeight: .infinity)
        .onPreferenceChange(SizeKey.self) { size = $0 }
    }
}

/// The all-day bar, drawn as an outline rather than a fill.
///
/// A pale tinted pill filling the cell width is what every calendar draws, so the shape
/// itself had become the cliche and no palette could get out from under it. An outline
/// spends almost no ink, and three stacked on one day stay three lines instead of
/// becoming a grey slab.
///
/// It carries no account. All-day events are holidays, birthdays and payments, and
/// which account they arrived in is the one thing nobody looks up.
private struct SpanBar: View {
    let seg: CalendarData.Segment
    var body: some View {
        HStack(spacing: 0) {
            Text(seg.openLeft || seg.item.isAllDay ? seg.item.title
                 : "\(Fmt.hm(seg.item.start)) \(seg.item.title)")
                .font(.mono(evFont - 1.5)).tracking(0.7).textCase(.uppercase)
                .foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 5)
            Spacer(minLength: 0)
        }
        .overlay(OutlineBox(openLeft: seg.openLeft, openRight: seg.openRight))
    }
}

private struct DayCell: View {
    @ObservedObject var data: CalendarData
    let day: Date
    let month: Date
    let lanes: Int
    let rowHeight: CGFloat
    @Binding var selected: Date?
    @State private var hover = false
    private let cal = Calendar.current

    private var outside: Bool { !cal.isDate(day, equalTo: month, toGranularity: .month) }
    private var isToday: Bool { cal.isDateInToday(day) }

    var body: some View {
        let timed = data.timed(on: day)
        // Show as many events as the space left by bars and the strip allows
        let strip: CGFloat = isPhone ? 15 : stripH
        let cap = max(1, Int((rowHeight - headH - CGFloat(lanes) * laneH - strip) / laneH))
        let w = data.workouts[cal.startOfDay(for: day)]
        let notes = data.notes[cal.startOfDay(for: day)] ?? []
        let jnotes = data.journalNotes[cal.startOfDay(for: day)] ?? []
        let dues = notes.filter(\.isDue)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                // Today is the one place colour appears in the month. The cell is not
                // inverted any more: a whole inverted cell is a large field of something,
                // and a page that has exactly one colour on it does not need the area.
                Text("\(cal.component(.day, from: day))")
                    .font(.mono(12, .medium))
                    .foregroundStyle(isToday ? .white : (outside ? Theme.inkFaint : Theme.inkDim))
                    .padding(.horizontal, isToday ? 5 : 0).padding(.vertical, isToday ? 1 : 0)
                    .background { if isToday { RoundedRectangle(cornerRadius: 3).fill(Theme.accent) } }
                if let t = w?.noteTitle, !t.isEmpty {
                    Text(t).font(.ui(10.5)).foregroundStyle(Theme.inkFaint).lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.top, 5)
            // Fixed, because the bars are placed at headH. A head that grew on the today
            // cell left the bars sitting across the first row of events.
            .frame(height: headH, alignment: .top)

            // The gap is the lane pitch less the line height, the same gap the bars
            // above leave between themselves, so the whole cell keeps one rhythm.
            VStack(alignment: .leading, spacing: laneH - evH) {
                ForEach(timed.prefix(cap)) { e in
                    if isPhone { PhoneEventRow(item: e) } else { EventRow(item: e) }
                }
                if timed.count > cap {
                    Text(isPhone ? "+\(timed.count - cap)" : "+\(timed.count - cap) more")
                        .font(isPhone ? Font.mono(9) : Font.ui(10.5))
                        .foregroundStyle(Theme.inkFaint)
                }
            }
            .padding(.top, CGFloat(lanes) * laneH)
            // The bars are inset this far from the cell edge; the rows share it.
            .padding(.horizontal, evInset)

            Spacer(minLength: 0)

            // The life strip. A rule along its top reads as a row boundary, so it fades
            // in from transparent instead.
            HStack(spacing: 5) {
                if let tags = w?.chip { WorkoutChip(tags: tags) }
                #if os(macOS)
                // A phone cell is about 55pt wide, which was not room enough for both
                // this and the workout tag: the two used to compete for the same
                // stretch of the life strip, and because the tag was the one asked to
                // give way, the count was what ended up sitting where the tag should
                // have read. The Mac cell has room for both.
                let rest = notes.count - dues.count + jnotes.count
                if rest > 0 {
                    HStack(spacing: 3) {
                        Rectangle().fill(Theme.inkDim).frame(width: 5, height: 5)
                        Text("\(rest)").font(.mono(10.5)).foregroundStyle(Theme.inkDim)
                    }
                    // Belt and suspenders: even here, the record is what this feature
                    // is for, so it is the count that gives way if space ever runs out.
                    .layoutPriority(-1)
                }
                #endif
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: isPhone ? 15 : stripH)
            .padding(.horizontal, 6)
            .background(LinearGradient(colors: [.clear, Theme.strip],
                                       startPoint: .top, endPoint: .bottom))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(outside ? Theme.sunk : Theme.surface)
        // A 2pt rule across the whole cell, so today is found while scanning a week
        // rather than only when the eye lands on the number.
        .overlay(alignment: .top) {
            if isToday { Rectangle().fill(Theme.accent).frame(height: 2) }
        }
        // Make it feel clickable.
        .overlay(Theme.ink.opacity(hover ? 0.05 : 0))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { selected = day }
    }
}

/// The time carries the account, in ink rather than in hue. See `Source.Chip`.
private struct EventRow: View {
    let item: Item
    var body: some View {
        HStack(spacing: 5) {
            TimeChip(text: Fmt.hm(item.start), source: item.source, size: 9.5)
            Text(item.title)
                .font(.ui(evFont)).foregroundStyle(Theme.ink)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(height: evH)
    }
}

/// A phone cell is about 55pt wide — too narrow to carry a time and a title side by
/// side, and the title is the half worth keeping. So the account's density moves onto
/// the title itself: the same four states, on the only thing there is room for.
private struct PhoneEventRow: View {
    let item: Item
    var body: some View {
        Text(item.title)
            .font(.ui(evFont))
            .foregroundStyle(item.source.chip == .solid ? Theme.surface : Theme.ink)
            .lineLimit(1).truncationMode(.tail)
            .density(item.source)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: evH)
    }
}

/// What was actually done that day. Records only — see `Workout.chip`.
///
/// Rounded, where the all-day bar above it is square. Both are outlined boxes and in a
/// cell with no all-day event the workout would otherwise read as one; an event is a
/// span and has ends, a record is a single fact and has none, so the silhouette says
/// which is which without depending on where in the cell it sits.
/// Nothing in a cell may claim a width of its own. The seven cells are equal because
/// each of them can shrink to nothing, and a single `fixedSize` here was enough to make
/// the day holding "Lower B · Stretching · yoga" wider than the six days beside it: the
/// row has to honour a minimum it cannot shrink past, and takes the space from its
/// neighbours. It was invisible while tags came from a fixed vocabulary and every one of
/// them was short. Tags are written by hand now, so the chip truncates instead.
private struct WorkoutChip: View {
    let tags: [String]
    var body: some View {
        Text(tags.map(Workout.label).joined(separator: " · "))
            .font(.mono(evFont - 1.5)).tracking(0.5).textCase(.uppercase)
            .foregroundStyle(Theme.ink)
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 6)
            .frame(height: 15)
            .overlay(OutlineBox(rounded: true))
    }
}

enum Fmt {
    static let hmF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    static func hm(_ d: Date) -> String { hmF.string(from: d) }
    static let ymdF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    static func ymd(_ d: Date) -> String { ymdF.string(from: d) }
}
