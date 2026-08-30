import SwiftUI

/// One editor handles both creating and editing. Two separate screens drift apart.
enum EditorTarget: Identifiable {
    case edit(Item)
    case create(Date)

    var id: String {
        switch self {
        case .edit(let i): return "edit-\(i.ekID)"
        case .create(let d): return "new-\(d.timeIntervalSince1970)"
        }
    }
    var item: Item? { if case .edit(let i) = self { return i }; return nil }
}

struct EventEditor: View {
    @ObservedObject var data: CalendarData
    let target: EditorTarget
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("lastCalendarID") private var lastCalendarID = ""
    @State private var title: String
    @State private var start: Date
    @State private var end: Date
    @State private var allDay: Bool
    @State private var calendarID: String
    @State private var error: String?
    @State private var confirmingDelete = false

    private var item: Item? { target.item }
    private var isNew: Bool { item == nil }
    private var editable: Bool { item?.writable ?? true }

    init(data: CalendarData, target: EditorTarget, onDone: @escaping () -> Void) {
        self.data = data; self.target = target; self.onDone = onDone
        switch target {
        case .edit(let i):
            _title = State(initialValue: i.title)
            _start = State(initialValue: i.start)
            _end = State(initialValue: i.end)
            _allDay = State(initialValue: i.isAllDay)
            _calendarID = State(initialValue: "")
        case .create(let day):
            // Default to the next full hour on that day, lasting one hour
            let c = Calendar.current
            let now = Date()
            let base = c.isDate(day, inSameDayAs: now)
                ? c.date(bySetting: .minute, value: 0, of: now.addingTimeInterval(3600)) ?? now
                : c.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
            _title = State(initialValue: "")
            _start = State(initialValue: base)
            _end = State(initialValue: base.addingTimeInterval(3600))
            _allDay = State(initialValue: false)
            _calendarID = State(initialValue: "")
        }
    }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 14) {
            fields
            HStack {
                deleteButton
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 470)
        .background(Theme.surface)
        .onAppear { if isNew { calendarID = defaultCalendarID() } }
        #else
        // A fixed-width sheet is cut off on a phone. Use a navigation sheet and move
        // Save and Cancel into the toolbar.
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fields
                    deleteButton
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.ground)
            .navigationTitle(isNew ? "New Event" : "Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") { commit() }.disabled(!canSave)
                }
            }
        }
        .onAppear { if isNew { calendarID = defaultCalendarID() } }
        #endif
    }

    private var canSave: Bool {
        editable && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder private var deleteButton: some View {
        if let i = item, i.writable {
            Button(confirmingDelete ? "Confirm delete" : "Delete") {
                if confirmingDelete { remove(i) } else { confirmingDelete = true }
            }
            .buttonStyle(.plain).font(.ui(12.5))
            .foregroundStyle(Theme.due)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .hoverable(tint: Theme.due)
        }
    }

    @ViewBuilder private var fields: some View {
        header

        TextField("Title", text: $title)
            .textFieldStyle(.plain).font(.ui(17, .medium))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.sunk)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .disabled(!editable)

        if isNew { calendarPicker }

        Toggle("All day", isOn: $allDay).font(.ui(12.5)).disabled(!editable)

        // Phones are too narrow for side-by-side pickers
        let pickers = Group {
            field("Start") {
                DatePicker("", selection: $start,
                           displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden().disabled(!editable)
            }
            field("End") {
                DatePicker("", selection: $end,
                           displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                    .labelsHidden().disabled(!editable)
            }
        }
        if isPhone {
            VStack(alignment: .leading, spacing: 12) { pickers }
        } else {
            HStack(spacing: 12) { pickers }
        }

        if let i = item, i.meetURL != nil || !i.location.isEmpty { location(i) }

        if let error {
            Text(error).font(.ui(12)).foregroundStyle(Theme.due)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Tapping the account line opens that account's web calendar on this date
    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            if let i = item {
                Circle().fill(i.source.color).frame(width: 10, height: 10)
                if let link = i.sourceLink {
                    Button { openExternal(link) } label: {
                        HStack(spacing: 4) {
                            Text(i.account.isEmpty ? i.calendar : i.account)
                            Image(systemName: "arrow.up.right.square").font(.system(size: 10))
                        }
                        .font(.ui(12)).foregroundStyle(i.source.color)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                    }
                    .buttonStyle(.plain).hoverable(radius: 5, tint: i.source.color)
                    .help("Open this account's calendar on this date")
                } else {
                    Text(i.calendar).font(.ui(12)).foregroundStyle(Theme.inkDim)
                }
                if !i.alsoIn.isEmpty {
                    Text("+\(i.alsoIn.count)").font(.mono(10)).foregroundStyle(Theme.inkFaint)
                }
            } else {
                Text("NEW EVENT").font(.mono(9.5)).tracking(0.9).foregroundStyle(Theme.inkFaint)
            }
            Spacer()
            if let i = item, !i.writable {
                Text("Read-only").font(.ui(11)).foregroundStyle(Theme.due)
            }
        }
    }

    private var calendarPicker: some View {
        field("Calendar") {
            Picker("", selection: $calendarID) {
                ForEach(data.writableCalendars) { c in
                    Text(c.label).tag(c.id)
                }
            }
            .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func location(_ i: Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LOCATION").font(.mono(9.5)).tracking(0.8).foregroundStyle(Theme.inkFaint)
            if let meet = i.meetURL {
                Button { openExternal(meet) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "video.fill").font(.system(size: 11))
                        Text("Join").font(.ui(12.5, .medium))
                        Text(meet.host ?? "").font(.ui(11)).foregroundStyle(Theme.inkDim)
                    }
                    .foregroundStyle(Theme.today)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.today.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).hoverable(tint: Theme.today)
            } else if !i.location.isEmpty {
                Button {
                    let q = i.location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let u = URL(string: "https://maps.apple.com/?q=\(q)") { openExternal(u) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse").font(.system(size: 11))
                        Text(i.location).font(.ui(12)).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(Theme.inkDim)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                }
                .buttonStyle(.plain).hoverable(radius: 5)
            }
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.mono(9.5)).tracking(0.8).foregroundStyle(Theme.inkFaint)
            c()
        }
    }

    /// Remembers the last calendar used, else the personal one, else the first.
    private func defaultCalendarID() -> String {
        let all = data.writableCalendars
        if let saved = all.first(where: { $0.id == lastCalendarID }) { return saved.id }
        if let personal = all.first(where: { $0.source == .personal }) { return personal.id }
        return all.first?.id ?? ""
    }

    private func commit() {
        guard end > start else { error = "End is before start."; return }
        let name = title.trimmingCharacters(in: .whitespaces)
        do {
            if let i = item {
                try data.save(i, title: name, start: start, end: end, allDay: allDay)
            } else {
                try data.create(title: name, start: start, end: end, allDay: allDay, calendarID: calendarID)
                lastCalendarID = calendarID
            }
            onDone(); dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func remove(_ i: Item) {
        do { try data.delete(i); onDone(); dismiss() }
        catch { self.error = error.localizedDescription; confirmingDelete = false }
    }
}
