import SwiftUI

/// Design-token palette mirroring Starlight's `Theme.qml`, so Skylight and Starlight share one
/// visual language (design-pairing-panel.md §3, "Visual redesign — concrete tokens"). Phase 1
/// (SAFE-AUTONOMOUS, see §7) applies these tokens to `PairingSheet` only, over the already-correct
/// view tree -- this file defines the tokens themselves, styling-only, no view logic.
///
/// Colors are resolved per `colorScheme` (light/dark hex pairs, §3.1); geometry and type sizes are
/// scheme-independent constants (§3.2).
enum SkylightTheme {
    /// Color tokens (§3.1, exact light/dark hex from the design doc). Construct with the current
    /// `colorScheme` -- typically via `@Environment(\.colorScheme)` in the consuming view.
    struct Colors {
        let scheme: ColorScheme

        init(_ scheme: ColorScheme) {
            self.scheme = scheme
        }

        private var isDark: Bool { scheme == .dark }

        var accent: Color { isDark ? Color(hex: 0x0A84FF) : Color(hex: 0x007AFF) }
        var accentPress: Color { isDark ? Color(hex: 0x2F96FF) : Color(hex: 0x0066D6) }
        /// Paired-success green.
        var ok: Color { isDark ? Color(hex: 0x30D158) : Color(hex: 0x34C759) }
        /// Destructive red (Deny, inline errors).
        var danger: Color { isDark ? Color(hex: 0xFF453A) : Color(hex: 0xFF3B30) }
        /// Opaque panel/sheet ground.
        var cardSolid: Color { isDark ? Color(hex: 0x2A2A2E) : Color(hex: 0xFFFFFF) }

        var hairline: Color { isDark ? Color.white.opacity(0.11) : Color.black.opacity(0.10) }
        /// Primary text.
        var label: Color { isDark ? Color.white.opacity(0.90) : Color.black.opacity(0.86) }
        /// Secondary text.
        var label2: Color { isDark ? Color.white.opacity(0.52) : Color.black.opacity(0.48) }
        /// Tertiary/hint text -- deliberately more de-emphasized than `label2`.
        var label3: Color { isDark ? Color.white.opacity(0.28) : Color.black.opacity(0.28) }
        /// Field/row fill.
        var segBg: Color { isDark ? Color.white.opacity(0.075) : Color.black.opacity(0.055) }
        /// accent @ 0.14 opacity, both schemes (§3.1).
        var rowSelectedBg: Color { accent.opacity(0.14) }
    }

    /// Corner-radius tokens (§3.2, from Theme.qml).
    enum Radius {
        static let card: CGFloat = 12
        static let group: CGFloat = 10
        static let control: CGFloat = 8
        static let chip: CGFloat = 6
    }

    /// Spacing scale (§3.2).
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 14
        static let l: CGFloat = 20
        static let xl: CGFloat = 28
    }

    /// Type point sizes (§3.2) -- weight/design stay caller-specified via `.font`.
    enum TypeSize {
        static let footnote: CGFloat = 11
        static let caption: CGFloat = 12
        static let body: CGFloat = 13
        static let headline: CGFloat = 16
        static let largeTitle: CGFloat = 25
    }
}

private extension Color {
    /// Solid `#RRGGBB` hex constructor for the token table's opaque colors (§3.1).
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
