import SwiftUI

@main
struct LayersApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    #endif

    var body: some Scene {
        #if os(macOS)
        // `Window`, not `WindowGroup`: Layers is one calendar, and a scene with a fixed
        // id is the only kind that can be reopened by name once it has been closed —
        // which it now can be, because closing it no longer ends the app.
        //
        // Fits a 13" screen without hiding behind the Dock; the minimum is low enough to shrink.
        Window("Layers", id: "main") { RootView() }
            .defaultSize(width: 1120, height: 720)
            .windowResizability(.contentMinSize)
        #else
        WindowGroup("Layers") { RootView() }
        #endif
    }
}

struct RootView: View {
    // Shared, because the alerts outlive the window now: with Layers in the menu bar the
    // calendar has to keep being read after the last window has gone.
    @ObservedObject private var data = CalendarData.shared
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var cursor = Date()
    @State private var selected: Date?
    @State private var mode: Mode =
        CommandLine.arguments.contains("-startInDay") ? .day : .month
    @State private var editor: EditorTarget?
    @State private var showFilters = false
    /// Which way the last step went, so the new page slides in from that side.
    @State private var dir = 1
    private let cal = Calendar.current
    enum Mode { case month, day }

    /// Changes exactly when the page changes, which is what drives the slide.
    private var pageKey: String {
        if mode == .day { return "d\(cal.startOfDay(for: selected ?? Date()).timeIntervalSince1970)" }
        let c = cal.dateComponents([.year, .month], from: cursor)
        return "m\(c.year ?? 0)-\(c.month ?? 0)"
    }

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
            .modifier(Paging(key: pageKey, back: dir < 0))
            // The outgoing page would otherwise slide out across the header.
            .clipped()
            .pagingSwipe { n in withAnimation(.easeOut(duration: 0.2)) { dir = n; shift(n) } }
        }
        .padding(.horizontal, isPhone ? 8 : 16)
        .padding(.top, isPhone ? 6 : 14).padding(.bottom, isPhone ? 4 : 16)
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 560)
        #endif
        .background(Theme.ground)
        #if os(macOS)
        // Lets both palettes be seen with real data without flipping the whole Mac's
        // appearance. Design work only: `open -n Layers.app --args -dark`.
        .preferredColorScheme(CommandLine.arguments.contains("-dark") ? .dark
                              : CommandLine.arguments.contains("-light") ? .light : nil)
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
        #if os(macOS)
        .onAppear { MenuBar.shared.reopen = { openWindow(id: "main") } }
        #endif
        #if os(macOS)
        // Raises a sample alert window so its look and its Join button can be checked
        // without waiting for a real meeting. Pair with -noNotify to leave the real
        // schedule alone: `open -n Layers.app --args -noNotify -testAlert`.
        .task {
            guard CommandLine.arguments.contains("-testAlert") else { return }
            try? await Task.sleep(for: .seconds(1))
            AlertWindows.shared.raise(EventAlert(
                id: "test-0", fire: Date(),
                item: Item(title: "Weekly sync with the coaching group",
                           start: Date(), end: Date().addingTimeInterval(1800),
                           isAllDay: false, source: .coaching, calendar: "Test",
                           writable: true, ekID: "test",
                           url: URL(string: "https://meet.google.com/abc-defg-hij")),
                minutes: 0))
            try? await Task.sleep(for: .seconds(1))
            AlertWindows.shared.raise(EventAlert(
                id: "test-30", fire: Date(),
                item: Item(title: "Dentist", start: Date().addingTimeInterval(1800),
                           end: Date().addingTimeInterval(3600), isAllDay: false,
                           source: .personal, calendar: "Test", writable: true,
                           ekID: "test2", location: "Novena Medical Center"),
                minutes: 30))
        }
        #endif
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
            if !isPhone { todayButton }
            Spacer(minLength: 4)
            if isPhone {
                iconButton("line.3.horizontal.decrease") { showFilters = true }
                todayButton
            }
            iconOrLabelNew
            Picker("", selection: $mode) {
                Text("Month").tag(Mode.month)
                Text("Day").tag(Mode.day)
            }
            .pickerStyle(.segmented).frame(width: isPhone ? 104 : 150).labelsHidden()
            // Left alone it paints itself in the system accent, which on a page with no
            // other hue on it is the loudest thing on screen and means nothing.
            .tint(Theme.ink)
        }
        .foregroundStyle(Theme.ink)
    }

    /// Works in both views: in the day view it opens today rather than only moving the
    /// month. A calendar glyph read as a view switch, so the word is spelled out.
    private var todayButton: some View {
        Button("Today") { cursor = Date(); selected = Date() }
            .buttonStyle(.plain)
            .font(.ui(isPhone ? 11.5 : 12.5)).foregroundStyle(Theme.inkDim)
            .padding(.horizontal, isPhone ? 8 : 11)
            .frame(height: isPhone ? 27 : 30)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: 1))
            .hoverable(radius: 7)
            // The month label has layout priority and would otherwise squeeze the word.
            .fixedSize()
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
                        AccountTag(source: s).opacity(on ? 1 : 0.32)
                        Spacer()
                        Text("\(data.items.filter { $0.source == s }.count)")
                            .font(.mono(12)).foregroundStyle(Theme.inkFaint)
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(on ? Theme.ink : Theme.inkFaint)
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
                    HStack(spacing: 6) {
                        AccountTag(source: s)
                        Text("\(n)").font(.mono(9.5)).foregroundStyle(Theme.inkFaint)
                    }
                    .padding(.horizontal, 4).padding(.vertical, 3)
                    // Off accounts fade rather than restyle: the density has to keep
                    // meaning the account even when the account is hidden.
                    .opacity(on ? 1 : 0.32)
                    .fixedSize()
                }
                .buttonStyle(.plain).hoverable(radius: 20)
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
            await Notifier.shared.start()
            // Alerts come from their own read of the coming week, not from `items`.
            // `items` holds whichever month is on screen, and scheduling from it wiped
            // every pending alert the moment you paged to another month.
            let up = data.upcoming(days: 7)
            Notifier.shared.schedule(up)
            #if os(macOS)
            MenuBar.shared.update(up)
            #endif
        }
    }
}

/// The page slides in from the side the swipe came from. Phone only: on the Mac a page
/// changes by button or arrow key, where a slide would be noise.
private struct Paging: ViewModifier {
    let key: String
    let back: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if isPhone {
            content.id(key).transition(.asymmetric(
                insertion: .move(edge: back ? .leading : .trailing),
                removal: .move(edge: back ? .trailing : .leading)))
        } else {
            content
        }
    }
}

extension Fmt {
    static let monthF: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; f.locale = Locale(identifier: "en_US"); return f
    }()
    static func monthLabel(_ d: Date) -> String { monthF.string(from: d) }
}
