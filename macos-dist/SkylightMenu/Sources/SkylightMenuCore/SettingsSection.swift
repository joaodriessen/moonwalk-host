import Foundation

/// The Settings window's sidebar sections (Tahoe-native redesign,
/// docs/design/2026-07-15-tahoe-native-redesign.md §2, owner-amended IA). Five sections, Status
/// first: `status, streaming, display, devices, network` -- NOT the design doc's 4-content-section
/// merge (owner explicitly rejected collapsing Display+Devices into one section). `streaming`
/// absorbs the old separate Quality and Sound sections; Display and Devices stay split, matching
/// today's shape. The former standalone `general` section was folded into `status` (its content
/// now lives at the bottom of `StatusPaneView`'s Form) and removed as its own sidebar entry.
///
/// Lives in `SkylightMenuCore` (moved out of the executable target's old local
/// `SettingsCatalog.swift` definition) so it's the single frozen contract both the menu-adjacent
/// code and the Settings window build against, and so it's unit-testable without SwiftUI. Chip
/// symbol/color are exposed as plain data (`String` / `SectionChipColor`), not a `Color`, so this
/// module stays SwiftUI-free -- the executable target's `SectionChip` view maps `chipColor` to an
/// actual `Color`.
public enum SettingsSection: String, CaseIterable, Identifiable, Equatable, Sendable {
    case status, streaming, display, devices, network

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .status: return "Status"
        case .streaming: return "Streaming"
        case .display: return "Display"
        case .devices: return "Devices"
        case .network: return "Network"
        }
    }

    /// Lucide glyph for the sidebar's colored chip (see the executable target's `SectionChip`
    /// view, which renders `chipGlyph` + `chipColor` together).
    public var chipGlyph: LucideGlyph {
        switch self {
        case .status: return .activity
        case .streaming: return .gauge
        case .display: return .monitor
        case .devices: return .laptopMinimal
        case .network: return .network
        }
    }

    /// Chip identity color. Static per section (identity, not state) -- the Status *pane*'s
    /// content carries live state; its chip does not change color with reachability (design §2.4:
    /// "chip is identity, not state").
    public var chipColor: SectionChipColor {
        switch self {
        case .status: return .teal
        case .streaming: return .blue
        case .display: return .indigo
        case .devices: return .purple
        case .network: return .green
        }
    }
}

/// A named color token for `SettingsSection.chipColor`, kept as data (not `SwiftUI.Color`) so
/// `SkylightMenuCore` has no SwiftUI dependency. The executable target's `SectionChip` view maps
/// each case to a `Color` (e.g. `.teal` -> `Color.teal`).
public enum SectionChipColor: String, CaseIterable, Hashable, Sendable {
    case teal, gray, blue, indigo, purple, green
}
