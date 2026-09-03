#if os(macOS)
import SwiftUI
import AppKit
import IOKit.pwr_mgt

// The alert Layers raises is its own window, not a system banner.
//
// A banner is the wrong shape for this. It is muted outright while the display sleeps
// (the system logs `muted by display state`), it is dismissed after five seconds, it
// cannot survive a Focus, and it never appears over a full-screen app — which is where
// you are when a call is about to start. A window Layers owns has none of those limits:
// it sits above full-screen apps, on every Space, and stays until it is answered.
//
// The cost is that it only exists while Layers runs. The scheduled system notification
// is still registered as the fallback for a quit app, and is withdrawn one alert at a
// time as the window takes each one over, so nothing is ever announced twice.

/// One raised alert and the panel showing it.
@MainActor
final class AlertWindows {
    static let shared = AlertWindows()
    private var open: [(id: String, panel: NSPanel)] = []

    /// A borderless panel is not key by default, and a panel that cannot become key
    /// swallows the click on Join.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// While Layers is not the active app — which is every time this window matters — a
    /// click on it is normally spent bringing the window forward, and the button under
    /// the pointer never sees it. The alert exists to be answered in one click, so the
    /// first one has to count.
    private final class Host<V: View>: NSHostingView<V> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func raise(_ a: EventAlert) {
        if open.contains(where: { $0.id == a.id }) { return }

        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 100),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        // Above full-screen apps and on whichever Space is in front. `.floating` sits
        // under a full-screen window, which is exactly when the alert matters most.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let host = Host(rootView: AlertCard(alert: a) { [weak self, weak panel] in
            if let panel { self?.close(panel) }
        })
        host.frame.size = host.fittingSize
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
        open.append((a.id, panel))
        stack()
        panel.orderFrontRegardless()

        // A meeting about to start is worth lighting the screen for. Without this the
        // panel is drawn to a sleeping display and seen whenever you next touch the Mac.
        if a.wakesDisplay { wakeDisplay() }
        NSSound(named: NSSound.Name(a.minutes == 0 ? "Submarine" : "Glass"))?.play()

        // The half-hour warning is a glance, not a decision, so it clears itself. The
        // five-minute and start alerts stay until they are answered.
        if !a.sticky {
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self, weak panel] in
                if let panel { self?.close(panel) }
            }
        }
    }

    private func close(_ panel: NSPanel) {
        panel.orderOut(nil)
        open.removeAll { $0.panel === panel }
        stack()
    }

    /// Down the top-right corner of whichever screen is in use — `NSScreen.main` is the
    /// one holding the focused window, so the alert lands where you are working rather
    /// than always on the built-in display.
    private func stack() {
        guard let area = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        var y = area.maxY - 12
        for (_, p) in open {
            p.setFrameOrigin(NSPoint(x: area.maxX - p.frame.width - 12, y: y - p.frame.height))
            y -= p.frame.height + 10
        }
    }

    /// Wakes the display the way pressing a key does. Public IOKit, no entitlement.
    private func wakeDisplay() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Layers event alert" as CFString,
                                         kIOPMUserActiveLocal, &id)
    }
}

/// Deliberately not a banner lookalike. It is wide enough for a real event title on two
/// lines and the Join button is the largest thing on it, because joining is the only
/// action anyone takes from a meeting alert.
private struct AlertCard: View {
    let alert: EventAlert
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                // The lead time takes the accent: an alert is the same kind of claim on
                // attention as today and the current hour, and it is the only thing on
                // the card worth colouring.
                Text(alert.lead)
                    .font(.mono(10.5, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 3))
                Text(alert.item.isAllDay ? "All day"
                     : "\(Fmt.hm(alert.item.start))–\(Fmt.hm(alert.item.end))")
                    .font(.mono(10.5)).foregroundStyle(Theme.inkDim)
                Spacer(minLength: 6)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.inkFaint)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain).hoverable(radius: 5)
            }

            Text(alert.item.title)
                .font(.ui(15, .semibold)).foregroundStyle(Theme.ink)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)

            if let where_ = alert.where_ {
                Text(where_).font(.ui(11.5)).foregroundStyle(Theme.inkDim)
                    .lineLimit(1).padding(.top, 3)
            }

            if let meet = alert.item.meetURL {
                Button {
                    openExternal(meet)
                    close()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "video.fill").font(.system(size: 11))
                        Text("Join").font(.ui(13, .semibold))
                    }
                    .foregroundStyle(Theme.surface)
                    .frame(maxWidth: .infinity).frame(height: 30)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .padding(.top, 11)
            }
        }
        .padding(13)
        .frame(width: 330, alignment: .leading)
        .background(Theme.surface)
        // A rule down the leading edge, inside the clip or its square corners stand
        // proud of the card's rounded ones. Ink, not the account: the card names one
        // event and there is nothing to tell it apart from.
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.ink).frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }
}
#endif
