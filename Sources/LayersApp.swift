import SwiftUI

@main
struct LayersApp: App {
    var body: some Scene {
        WindowGroup("Layers") { RootView() }
        #if os(macOS)
            // Fits a 13" screen without hiding behind the Dock; the minimum is low enough to shrink.
            .defaultSize(width: 1120, height: 720)
            .windowResizability(.contentMinSize)
        #endif
    }
}

struct RootView: View {
    @StateObject private var data = CalendarData()
    @State private var cursor = Date()
    @State private var selected: Date?
    @State private var mode: Mode =
        CommandLine.arguments.contains("-startInDay") ? .day : .month
    @State private var editor: EditorTarget?
    @State private var showFilters = false
    private let cal = Calendar.current
    enum Mode { case month, day }

    var body: some View {
        VStack(spacing: isPhone ? 8 : 12) {
            header
            if !isPhone { rail }
            Group {
                if mode == .month {
                    MonthView(data: data, cursor: $cursor, selected: Binding(
                        get: { selected },
                        set: { d in selected = d; if d != nil { mode = .day } }))
                } else {
                    DayView(data: data, day: selected ?? Date(), editor: $editor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, isPhone ? 8 : 16)
        .padding(.top, isPhone ? 6 : 14).padding(.bottom, isPhone ? 4 : 16)
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
        #endif
        .background(Theme.ground)
        #if os(macOS)
        .focusable()
        .onKeyPress(.leftArrow) { shift(-1); return .handled }
        .onKeyPress(.rightArrow) { shift(1); return .handled }
        .onKeyPress(.init("m")) { mode = .month; return .handled }
        .onKeyPress(.init("d")) { mode = .day; return .handled }
        #endif
        .sheet(isPresented: $showFilters) { filterSheet }
        .sheet(item: $editor) { t in
            EventEditor(data: data, target: t) { Task { await reload() } }
        }
        .task { await reload() }
        .onChange(of: cursor) { _, _ in Task { await reload() } }
    }

    private var header: some View {
        HStack(spacing: isPhone ? 2 : 6) {
            navButton("‹") { shift(-1) }
            Text(Fmt.monthLabel(mode == .day ? (selected ?? Date()) : cursor))
                .font(.mono(isPhone ? 13 : 17, .medium))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(minWidth: isPhone ? 0 : 150)
                .layoutPriority(1)
            navButton("›") { shift(1) }
            if !isPhone {
                Button("Today") { cursor = Date(); selected = Date() }
                    .buttonStyle(.plain)
                    .font(.ui(12.5)).foregroundStyle(Theme.inkDim)
                    .padding(.horizontal, 11).frame(height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
                    .hoverable(radius: 7)
            }
            Spacer(minLength: 4)
            if isPhone {
                iconButton("line.3.horizontal.decrease") { showFilters = true }
                iconButton("calendar") { cursor = Date(); selected = Date() }
            }
            iconOrLabelNew
            Picker("", selection: $mode) {
                Text("Month").tag(Mode.month)
                Text("Day").tag(Mode.day)
            }
            .pickerStyle(.segmented).frame(width: isPhone ? 104 : 150).labelsHidden()
        }
        .foregroundStyle(Theme.ink)
    }

    @ViewBuilder private var iconOrLabelNew: some View {
        if isPhone {
            iconButton("plus") { editor = .create(selected ?? cursor) }
        } else {
            Button { editor = .create(selected ?? cursor) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    Text("New").font(.ui(12.5))
                }
                .foregroundStyle(Theme.inkDim)
                .padding(.horizontal, 11).frame(height: 30)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
            }
            .buttonStyle(.plain).hoverable(radius: 7)
            #if os(macOS)
            .keyboardShortcut("n", modifiers: .command)
            #endif
        }
    }

    private func iconButton(_ name: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: name).font(.system(size: 12))
                .foregroundStyle(Theme.inkDim)
                .frame(width: isPhone ? 27 : 30, height: isPhone ? 27 : 30)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain).hoverable(radius: 7)
    }

    /// On a phone the account filter moves into a sheet. Left inline, the labels break
    /// into single stacked letters.
    private var filterSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ACCOUNTS").font(.mono(10)).tracking(1).foregroundStyle(Theme.inkFaint)
            ForEach(Source.allCases, id: \.self) { s in
                let on = !data.hidden.contains(s)
                Button {
                    if on { data.hidden.insert(s) } else { data.hidden.remove(s) }
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(on ? s.color : Theme.inkFaint).frame(width: 11, height: 11)
                        Text(s.label).font(.ui(15))
                        Spacer()
                        Text("\(data.items.filter { $0.source == s }.count)")
                            .font(.mono(12)).foregroundStyle(Theme.inkFaint)
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(on ? s.color : Theme.inkFaint)
                    }
                    .foregroundStyle(Theme.ink)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button("Done") { showFilters = false }.frame(maxWidth: .infinity)
        }
        .padding(20)
        .background(Theme.ground)
    }

    private var rail: some View {
        HStack(spacing: 6) {
            ForEach(Source.allCases, id: \.self) { s in
                let on = !data.hidden.contains(s)
                let n = data.items.filter { $0.source == s }.count
                Button {
                    if on { data.hidden.insert(s) } else { data.hidden.remove(s) }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(on ? s.color : Theme.inkFaint).frame(width: 7, height: 7)
                        Text(s.label).font(.ui(11))
                        Text("\(n)").font(.mono(9.5)).foregroundStyle(Theme.inkFaint)
                    }
                    .foregroundStyle(on ? Theme.ink : Theme.inkDim)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                    .opacity(on ? 1 : 0.45)
                    .fixedSize()
                }
                .buttonStyle(.plain).hoverable(radius: 20, tint: s.color)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
    }

    private func navButton(_ s: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(s).font(.system(size: isPhone ? 15 : 17)).foregroundStyle(Theme.inkDim)
                .frame(width: isPhone ? 26 : 30, height: isPhone ? 26 : 30)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        // .plain makes only the glyph clickable; hoverable restores the full rectangle.
        .hoverable(radius: 7)
    }

    private func shift(_ n: Int) {
        if mode == .day {
            selected = cal.date(byAdding: .day, value: n, to: selected ?? Date())
            cursor = selected ?? cursor
        } else {
            // Step from the first of the month; stepping from the 31st can skip a month.
            let first = cal.date(from: cal.dateComponents([.year, .month], from: cursor))!
            cursor = cal.date(byAdding: .month, value: n, to: first)!
        }
    }

    /// Loads a margin either side of the visible month, because week rows overlap neighbours.
    private func reload() async {
        let first = cal.date(from: cal.dateComponents([.year, .month], from: cursor))!
        await data.load(from: cal.date(byAdding: .day, value: -14, to: first)!,
                        to: cal.date(byAdding: .day, value: 60, to: first)!)
        // Ask for notification permission only once there is something to notify about.
        if !data.items.isEmpty, !CommandLine.arguments.contains("-noNotify") {
            Notifier.shared.start()
            Notifier.shared.schedule(data.items)
        }
    }
}

extension Fmt {
    static let monthF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; f.locale = Locale(identifier: "en_US"); return f
    }()
    static func monthLabel(_ d: Date) -> String { monthF.string(from: d) }
}
