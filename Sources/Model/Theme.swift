import SwiftUI

enum Theme {
    static let ground   = Color.dual(0xFFFFFF, 0x1C2A38)
    static let surface  = Color.dual(0xFFFFFF, 0x1C2A38)
    static let sunk     = Color.dual(0xF3F8FA, 0x243748)   // cells outside the shown month
    static let line     = Color.dual(0xDEE8EC, 0x2B3E50)
    static let lineSoft = Color.dual(0xEDF3F6, 0x233444)
    static let ink      = Color.dual(0x283E56, 0xF4EADC)
    static let inkDim   = Color.dual(0x6E7F92, 0x9BABBA)
    static let inkFaint = Color.dual(0xA9B2BB, 0x65788B)
    static let strip    = Color.dual(0xF5FAFC, 0x21303E)   // the life strip at the foot of each cell
    static let today    = Color.dual(0x1989AC, 0x4FC3E8)
    static let workout  = Color.dual(0x1F8A72, 0x4FC7A4)
    static let due      = Color.dual(0x970747, 0xF5789F)

}

extension Font {
    /// Body text. The system font renders Korean properly (Apple SD Gothic Neo);
    /// a named font that is not installed falls back silently and looks broken.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Times and dates. Equal digit widths keep columns aligned.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Account group. Colour encodes only this. Letting it carry a second meaning
/// makes the month view unreadable.
enum Source: String, CaseIterable, Codable {
    case personal, coaching, work, holiday

    var label: String {
        switch self {
        case .personal: return "Personal"
        case .coaching: return "Coaching"
        case .work:     return "Work"
        case .holiday:  return "Holidays"
        }
    }

    /// Personal is 67% of all events, so its colour must stay quiet.
    /// Colour marks the exception, not the rule.
    var color: Color {
        switch self {
        case .personal: return .dual(0x93A2B0, 0x8E9FAF)
        case .coaching: return .dual(0x970747, 0xF0669B)
        case .work:     return .dual(0x1989AC, 0x4FC3E8)
        case .holiday:  return .dual(0xC08A2E, 0xE0A94F)
        }
    }
}

/// Anything clickable responds on hover. Without it people cannot tell it is a control.
struct Hoverable: ViewModifier {
    var radius: CGFloat = 6
    var tint: Color = Theme.ink
    @State private var over = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius).fill(tint.opacity(over ? 0.08 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .onHover { over = $0 }
    }
}

extension View {
    func hoverable(radius: CGFloat = 6, tint: Color = Theme.ink) -> some View {
        modifier(Hoverable(radius: radius, tint: tint))
    }
}
