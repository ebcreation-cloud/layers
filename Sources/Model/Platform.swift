import SwiftUI

// Everything that differs between macOS and iOS lives here. Scattering #if through
// the view code invites fixing one platform and forgetting the other.

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor

/// Opens a URL. Used by the Join button and by notification actions.
@MainActor func openExternal(_ url: URL) { NSWorkspace.shared.open(url) }

/// Narrow screen. A phone month cell is about 55pt wide, too narrow for text,
/// so the layout differs rather than just shrinking.
///
/// `-phone` forces it on, because the phone layout is the one that cannot be checked
/// where the real calendar is: the simulator has no events in it.
let isPhone = CommandLine.arguments.contains("-phone")

extension PlatformColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    /// Defines light and dark as a pair, so no colour is ever defined for only one theme.
    static func dual(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

#else
import UIKit
typealias PlatformColor = UIColor

@MainActor func openExternal(_ url: URL) { UIApplication.shared.open(url) }

let isPhone = UIDevice.current.userInterfaceIdiom == .phone

extension PlatformColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    static func dual(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}
#endif

// MARK: - Paging by swipe

#if os(macOS)
extension View {
    /// No-op on the Mac, where paging is the ‹ › buttons and the arrow keys. A trackpad
    /// swipe there is a scroll, and claiming it would fight the month grid.
    func pagingSwipe(_ step: @escaping (Int) -> Void) -> some View { self }
}
#else
extension View {
    /// A sideways drag pages: one month in the month view, one day in the day view.
    /// `step` gets -1 for back and +1 for forward.
    ///
    /// Simultaneous, not exclusive: the day view scrolls vertically underneath, and a
    /// plain `.gesture` swallows that scroll entirely.
    func pagingSwipe(_ step: @escaping (Int) -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { v in
                    // Sideways only, and by a clear margin. Without the comparison a
                    // diagonal flick while scrolling the hours changes the day under
                    // the finger.
                    let dx = v.translation.width, dy = v.translation.height
                    guard abs(dx) > 56, abs(dx) > abs(dy) * 1.6 else { return }
                    step(dx < 0 ? 1 : -1)
                })
    }
}
#endif
