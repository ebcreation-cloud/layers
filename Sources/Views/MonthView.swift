import SwiftUI

private let laneH: CGFloat = 17
private let headH: CGFloat = 24
// Week height follows the window. Pinning it meant a six-week month overflowed a 13"
// screen and the last row hid behind the Dock. Every week still shares one height,
// because they all shrink together.
private let rowMinH: CGFloat = 78
private let stripH: CGFloat = 26
private let evH: CGFloat = 16

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

    /// Width of one cell. Six 1pt gaps sit between the seven cells.
    private var colW: CGFloat { max(0, (size.width - 6) / 7) }

    var body: some View {
        let segs = data.segments(weekStart: days[0])
        let lanes = (segs.map(\.lane).max() ?? -1) + 1
        ZStack(alignment: .topLeading) {
            HStack(spacing: 1) {
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
                    let lead: CGFloat = seg.openLeft ? 0 : 4
                    let trail: CGFloat = seg.openRight ? 0 : 4
                    SpanBar(seg: seg)
                        .frame(width: max(0, (colW + 1) * span - 1 - lead - trail), height: 15)
                        .offset(x: (colW + 1) * CGFloat(seg.startCol) + lead,
                                y: headH + CGFloat(seg.lane) * laneH)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: rowMinH, maxHeight: .infinity)
        .onPreferenceChange(SizeKey.self) { size = $0 }
    }
}

private struct SpanBar: View {
    let seg: CalendarData.Segment
    var body: some View {
        let c = seg.item.source.color
        HStack(spacing: 0) {
            if !seg.openLeft { Rectangle().fill(c).frame(width: 2) }
            Text(seg.openLeft || seg.item.isAllDay ? seg.item.title : "\(Fmt.hm(seg.item.start)) \(seg.item.title)")
                .font(.ui(10.5, .medium))
                .foregroundStyle(c.mix(with: Theme.ink, by: 0.2))
                .lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 6)
            Spacer(minLength: 0)
        }
        .background(c.opacity(0.17))
        .clipShape(.rect(topLeadingRadius: seg.openLeft ? 0 : 3, bottomLeadingRadius: seg.openLeft ? 0 : 3,
                         bottomTrailingRadius: seg.openRight ? 0 : 3, topTrailingRadius: seg.openRight ? 0 : 3))

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
        let lineH: CGFloat = isPhone ? 11 : evH
        let strip: CGFloat = isPhone ? 15 : stripH
        let cap = max(1, Int((rowHeight - headH - CGFloat(lanes) * laneH - strip) / lineH))
        let w = data.workouts[cal.startOfDay(for: day)]
        let notes = data.notes[cal.startOfDay(for: day)] ?? []
        let jnotes = data.journalNotes[cal.startOfDay(for: day)] ?? []
        let dues = notes.filter(\.isDue)

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text("\(cal.component(.day, from: day))")
                    .font(.mono(12, isToday ? .semibold : .medium))
                    // On an inverted cell the disc must be light and the digits dark, or nothing shows
                    .foregroundStyle(isToday ? Theme.ink : (outside ? Theme.inkFaint : Theme.inkDim))
                    .frame(width: isToday ? 19 : nil, height: isToday ? 19 : nil)
                    .background { if isToday { Circle().fill(Theme.surface) } }
                if let t = w?.noteTitle, !t.isEmpty {
                    Text(t).font(.ui(10.5))
                        .foregroundStyle(isToday ? Theme.surface.opacity(0.6) : Theme.inkFaint)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.top, 5)

            if isPhone {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(timed.prefix(max(1, cap))) { e in
                        HStack(spacing: 2) {
                            Rectangle().fill(e.source.color).frame(width: 2)
                            Text(e.title)
                                .font(.ui(8.5))
                                .foregroundStyle(isToday ? Theme.surface : Theme.ink)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .frame(height: 11)
                    }
                    if timed.count > max(1, cap) {
                        Text("+\(timed.count - max(1, cap))")
                            .font(.mono(7.5))
                            .foregroundStyle(isToday ? Theme.surface.opacity(0.5) : Theme.inkFaint)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, CGFloat(lanes) * laneH + 1)
                .padding(.horizontal, 3)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(timed.prefix(cap)) { e in EventRow(item: e, inverted: isToday) }
                    if timed.count > cap {
                        Text("+\(timed.count - cap) more").font(.ui(10.5))
                            .foregroundStyle(isToday ? Theme.surface.opacity(0.5) : Theme.inkFaint)
                            .padding(.leading, 4)
                    }
                }
                .padding(.top, CGFloat(lanes) * laneH)
                .padding(.horizontal, 5)
            }

            Spacer(minLength: 0)

            // The life strip. A rule along its top reads as a row boundary, so it fades
            // in from transparent instead.
            HStack(spacing: 5) {
                if let chip = w?.chip { WorkoutChip(chip: chip, inverted: isToday) }
                let rest = notes.count - dues.count + jnotes.count
                if rest > 0 {
                    HStack(spacing: 3) {
                        Rectangle().fill(isToday ? Theme.surface.opacity(0.6) : Theme.inkDim).frame(width: 5, height: 5)
                        Text("\(rest)").font(.mono(10.5))
                            .foregroundStyle(isToday ? Theme.surface.opacity(0.6) : Theme.inkDim)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: isPhone ? 15 : stripH)
            .padding(.horizontal, 6)
            .background(LinearGradient(colors: [.clear, isToday ? Theme.ink.opacity(0.55) : Theme.strip],
                                       startPoint: .top, endPoint: .bottom))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isToday ? Theme.ink : (outside ? Theme.sunk : Theme.surface))
        // Make it feel clickable. The inverted today cell lifts toward light instead.
        .overlay((isToday ? Theme.surface : Theme.today).opacity(hover ? 0.07 : 0))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { selected = day }
    }
}

/// The tinted box around the time carries the account colour. A dot or a thin rule
/// gave too little colour area to tell three accounts apart.
private struct EventRow: View {
    let item: Item
    let inverted: Bool
    var body: some View {
        HStack(spacing: 5) {
            Text(Fmt.hm(item.start))
                .font(.mono(10, .medium))
                .foregroundStyle(item.source.color.mix(with: inverted ? Theme.surface : Theme.ink, by: 0.14))
                .padding(.horizontal, 4)
                .frame(height: 14)
                .background(item.source.color.opacity(inverted ? 0.36 : 0.24))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(item.title)
                .font(.ui(11.5))
                .foregroundStyle(inverted ? Theme.surface : Theme.ink)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .frame(height: evH)
    }
}

/// Three steps of one green. The solid fill means a record line was actually written.
private struct WorkoutChip: View {
    let chip: (level: Workout.Level, tags: [String])
    let inverted: Bool

    var body: some View {
        let text = chip.tags.map(Workout.label).joined(separator: " · ")
        let w = Theme.workout
        HStack(spacing: 0) {
            if chip.level != .plan { Rectangle().fill(w.opacity(chip.level == .done ? 1 : 0.45)).frame(width: 2) }
            Text(text).font(.ui(10.5, .medium))
                .foregroundStyle(chip.level == .plan ? w.opacity(0.6)
                                 : w.mix(with: inverted ? Theme.surface : Theme.ink, by: 0.22))
                .lineLimit(1).fixedSize().padding(.horizontal, 6)
        }
        .frame(height: 15)
        .background(chip.level == .plan ? Color.clear : w.opacity(chip.level == .done ? 0.18 : 0.08))
        .overlay {
            if chip.level == .plan {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2.5, 2.5]))
                    .foregroundStyle(w.opacity(0.35))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

enum Fmt {
    static let hmF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    static func hm(_ d: Date) -> String { hmF.string(from: d) }
}
