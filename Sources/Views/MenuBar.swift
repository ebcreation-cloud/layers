#if os(macOS)
import AppKit
import SwiftUI

// Layers lives in the menu bar so that closing the window does not end the alerts.
//
// The window is the calendar; the menu bar item is what keeps the app alive to raise an
// alert twenty minutes after you last looked at it. It also carries the one thing worth
// knowing without opening anything: what is next, and how long you have.

@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    static let shared = MenuBar()

    /// Rebuilds the window after it has been closed rather than merely hidden. Set by
    /// the view, because only a SwiftUI scene can open a SwiftUI window.
    var reopen: (() -> Void)?

    private var item: NSStatusItem?
    private var upcoming: [Item] = []
    private var ticker: Timer?

    func install() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.image = NSImage(systemSymbolName: "square.stack",
                                   accessibilityDescription: "Layers")
        it.button?.imagePosition = .imageLeading
        let m = NSMenu()
        m.delegate = self
        it.menu = m
        item = it

        // A minute is too coarse for a countdown people read to decide when to leave.
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.paint() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        paint()
    }

    func update(_ items: [Item]) {
        upcoming = items.filter { !$0.isAllDay }.sorted { $0.start < $1.start }
        paint()
    }

    /// What is next, counting something that started a few minutes ago as still next:
    /// a meeting you are late for is the one you want named.
    private var next: Item? {
        let floor = Date().addingTimeInterval(-5 * 60)
        return upcoming.first { $0.start > floor }
    }

    /// The next event is named only while it is close. A title sitting in the menu bar
    /// all day is a title nobody reads; one that appears an hour out is the exception,
    /// and that is what makes it worth a glance.
    private func paint() {
        guard let button = item?.button else { return }
        guard let n = next else { button.title = ""; return }
        let mins = Int((n.start.timeIntervalSinceNow / 60).rounded(.down))
        guard mins <= 60 else { button.title = ""; return }
        let head = mins <= 0 ? "now" : "\(mins)m"
        button.title = "  \(head) · \(n.title.prefix(22))"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let n = next {
            let when = Fmt.hm(n.start)
            let head = NSMenuItem(title: "\(when)  \(n.title)", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            if n.meetURL != nil {
                menu.addItem(withTitle: "Join meeting", action: #selector(join), keyEquivalent: "")
                    .target = self
            }
        } else {
            let head = NSMenuItem(title: "Nothing scheduled", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Layers", action: #selector(open), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Layers", action: #selector(quit), keyEquivalent: "q")
            .target = self
    }

    @objc private func join() {
        if let u = next?.meetURL { openExternal(u) }
    }

    /// Two ways in, because a closed window and a hidden one need different things and
    /// the app cannot tell which it has from the outside.
    @objc func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            reopen?()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

/// Keeps the app alive with its window closed, and keeps the alerts fed while it is.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var refresher: Timer?

    /// The whole point of the menu bar item. Without this the last window closing takes
    /// every pending alert with it.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated { MenuBar.shared.install() }

        // Reloads used to come from the window, and the window can now be closed. Without
        // a beat of its own the alert queue would stay whatever the calendar looked like
        // when it was last opened, and an event added on the phone this afternoon would
        // never raise anything.
        let t = Timer(timeInterval: 600, repeats: true) { _ in
            Task { @MainActor in Self.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        refresher = t

        // EventKit says when something changed, which beats waiting out the ten minutes.
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
                Task { @MainActor in Self.refresh() }
            }
    }

    @MainActor static func refresh() {
        let up = CalendarData.shared.upcoming(days: 7)
        guard !up.isEmpty else { return }
        // -noNotify has to hold here too, or a second copy run for testing would clear
        // the real one's pending alerts out from under it.
        if !CommandLine.arguments.contains("-noNotify") { Notifier.shared.schedule(up) }
        MenuBar.shared.update(up)
    }

    /// Clicking the Dock icon with no window open should bring the calendar back.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool {
        if !f { MainActor.assumeIsolated { MenuBar.shared.open() } }
        return true
    }
}
#endif
