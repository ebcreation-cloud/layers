import SwiftUI

enum Theme {
    // Paper and ink, and one colour.
    //
    // The ground is warm off-white rather than white and the ink is warm near-black
    // rather than black: pure #FFF against pure #000 is a screen, and this is meant to
    // read as a printed sheet. Dark is the same relationship turned over.
    static let ground   = Color.dual(0xF2F1EC, 0x0E0F0E)   // behind the sheet
    static let surface  = Color.dual(0xFAFAF8, 0x131414)   // the sheet itself
    static let sunk     = Color.dual(0xF1F0EB, 0x181918)   // cells outside the shown month
    static let line     = Color.dual(0xD9D8D1, 0x2E302E)
    static let lineSoft = Color.dual(0xE6E5DE, 0x232523)
    static let ink      = Color.dual(0x1A1A19, 0xEDEEEB)
    static let inkDim   = Color.dual(0x63635F, 0x9A9C98)
    static let inkFaint = Color.dual(0xA2A29C, 0x6A6C69)
    static let strip    = Color.dual(0xF2F1EC, 0x1A1B1A)

    /// The only colour in the app, and it appears in four places: today, the current
    /// hour, a deadline, and delete. Nothing else may take it — a page with one colour
    /// on it points at something; a page with three decorates.
    ///
    /// Deadline and delete share it with today on purpose. They are told apart by a
    /// mark, not a hue: a deadline carries an exclamation and delete is a button you
    /// had to open an editor to reach. Dark needs the brighter value or the same red
    /// reads muddy against near-black.
    static let accent   = Color.dual(0xFF3B21, 0xFF5334)
}

extension Font {
    /// Body text. The system font renders Korean properly (Apple SD Gothic Neo);
    /// a named font that is not installed falls back silently and looks broken.
    ///
    /// Everything in the grid is set at regular weight. Medium was carrying emphasis
    /// back when colour marked the account and the type had to hold its own beside it;
    /// on a page of hairlines and outlines the same weight reads as heavy, and there is
    /// nothing left for it to compete with.
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

    /// How much ink the time chip holds. Colour used to carry the account; on a page
    /// with no hue left on it, the same job is done by density, and the tinted box
    /// around the time was already the thing carrying it — a dot or a thin rule gave
    /// too little area to tell three accounts apart, let alone four.
    ///
    /// Personal is about two thirds of all events, so it holds no ink at all. The
    /// quiet one has to stay quiet; density marks the exception, not the rule.
    enum Chip { case bare, tint, solid, outline }

    var chip: Chip {
        switch self {
        case .personal: return .bare
        case .coaching: return .tint
        case .work:     return .solid
        case .holiday:  return .outline
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
    /// The account's ink density, as a background on whatever it wraps. See `Source.Chip`.
    /// The caller sets its own foreground, because the same density sits behind a dim
    /// time on the Mac and a full-strength title on the phone.
    @ViewBuilder func density(_ source: Source) -> some View {
        let padded = source.chip != .bare
        self
            .padding(.horizontal, padded ? 4 : 0)
            .padding(.vertical, padded ? 1 : 0)
            .background {
                switch source.chip {
                case .tint:    RoundedRectangle(cornerRadius: 2).fill(Theme.ink.opacity(0.14))
                case .solid:   RoundedRectangle(cornerRadius: 2).fill(Theme.ink)
                case .outline: RoundedRectangle(cornerRadius: 2).stroke(Theme.ink, lineWidth: 1)
                case .bare:    Color.clear
                }
            }
    }
}

/// The time, carrying its account in how much ink it holds. See `Source.Chip`.
struct TimeChip: View {
    let text: String
    let source: Source
    var size: CGFloat = 9.5

    var body: some View {
        Text(text)
            .font(.mono(size))
            .foregroundStyle(source.chip == .solid ? Theme.surface
                             : source.chip == .bare ? Theme.inkFaint : Theme.ink)
            .density(source)
            .fixedSize()
    }
}

/// The filter's legend, which is the encoding itself: each account's name is set in
/// the same ink density that account's times are set in. A separate key would have to
/// be learned; this one can only be read.
struct AccountTag: View {
    let source: Source
    var body: some View {
        Text(source.label)
            .font(.ui(11))
            .foregroundStyle(source.chip == .solid ? Theme.surface
                             : source.chip == .bare ? Theme.inkDim : Theme.ink)
            .padding(.horizontal, source.chip == .bare ? 2 : 2)
            .density(source)
    }
}

/// A box drawn as an outline, not a fill: the all-day bar and the workout record.
///
/// `openLeft` / `openRight` drop the end cap where a bar is clipped at a week edge, so
/// it reads as continuing rather than as an event that happens to end on Saturday.
struct OutlineBox: View {
    var openLeft = false
    var openRight = false
    var rounded = false
    var tint: Color = Theme.ink

    var body: some View {
        if rounded {
            Capsule().stroke(tint, lineWidth: 1)
        } else {
            ZStack {
                VStack(spacing: 0) {
                    Rectangle().fill(tint).frame(height: 1)
                    Spacer(minLength: 0)
                    Rectangle().fill(tint).frame(height: 1)
                }
                HStack(spacing: 0) {
                    if !openLeft { Rectangle().fill(tint).frame(width: 1) }
                    Spacer(minLength: 0)
                    if !openRight { Rectangle().fill(tint).frame(width: 1) }
                }
            }
        }
    }
}

extension View {
    func hoverable(radius: CGFloat = 6, tint: Color = Theme.ink) -> some View {
        modifier(Hoverable(radius: radius, tint: tint))
    }
}
