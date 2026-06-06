import SwiftUI
import AppKit

/// Single source of truth for the palette. Every color lives here so the UI
/// stays consistent — and follows the accent color the user picks in
/// System Settings ▸ Appearance instead of a baked-in brand color.
enum Theme {
    /// The system accent (Multicolor → whatever the user chose: blue, purple,
    /// graphite, …). A dynamic `NSColor`, so it tracks live changes and the
    /// active appearance. Everything tinted in the app derives from this.
    static let accent = Color(nsColor: .controlAccentColor)
    static let accentSoft = accent.opacity(0.18)

    /// Neutral, untinted window base — dark near-black or light near-white per the
    /// system appearance — so *any* accent reads cleanly on top, the way Apple's
    /// own windows stay neutral and reserve color for selection and controls.
    static let windowBackground = dynamic(
        light: NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1),
        dark: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    )

    /// Slightly raised surface for inset controls (search field, picker) — a hair
    /// of lift off the base. Tints flip black-on-light / white-on-dark so the
    /// "lift" reads in both appearances.
    static let surface = dynamic(light: NSColor(white: 0, alpha: 0.04),
                                 dark: NSColor(white: 1, alpha: 0.05))
    static let surfaceStroke = dynamic(light: NSColor(white: 0, alpha: 0.12),
                                       dark: NSColor(white: 1, alpha: 0.09))

    // Hairline / selection tints.
    static let hairline = dynamic(light: NSColor(white: 0, alpha: 0.10),
                                  dark: NSColor(white: 1, alpha: 0.07))
    static let rowHover = accent.opacity(0.12)

    static let windowWidth: CGFloat = 380
    static let windowHeight: CGFloat = 520

    /// A `Color` backed by a dynamic `NSColor` that resolves per the active
    /// appearance — so it tracks the system light/dark switch automatically.
    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// A monospaced badge chip, e.g. `.swift` or `https`. The recurring visual motif
/// — carries either a file extension or a URL scheme.
struct BadgeChip: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(Theme.accent)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.accentSoft, in: Capsule())
    }
}
