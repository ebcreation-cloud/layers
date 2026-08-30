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
let isPhone = false

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
