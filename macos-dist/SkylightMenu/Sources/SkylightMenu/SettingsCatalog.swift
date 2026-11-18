import SwiftUI
import AppKit
import SkylightMenuCore

/// Hand-authored presentation chrome for the redesigned Settings window
/// (docs/design/2026-07-15-tahoe-native-redesign.md, owner-amended IA: Status / General /
/// Streaming / Display / Devices / Network — six sidebar sections, Status first).
///
/// `SettingsSection` (the section identities + their SF Symbol/tint) is frozen scaffolding owned
/// elsewhere in this target — this file only keeps the reusable SwiftUI chrome: the sidebar chip,
/// the "Advanced" disclosure shell, and the window-level restart-pending banner. The old
/// `SettingsRow` (a `VStack` of label/content/caption) is retired entirely — every row is now a
/// native `Toggle`/`Picker`/`LabeledContent` with its caption either promoted to a real `Section`
/// footer (single-control sections) or kept as a plain secondary `Text` directly under the control
/// (multi-control Advanced groups, where a Form `Section` footer can't target one specific row).
///
/// The pure, non-SwiftUI option-abstraction enums (`VideoCodec`, `SoftwarePreset`,
/// `DisplayMatchOption`, `DisplayActivation`, `EncryptionMode`, `WebConsoleAccess`, `ConfigBool`,
/// `PairedClient`) live in `SkylightMenuCore/SettingsCatalogCore.swift`; only the View chrome and
/// one display-only copy fix (below) live here.

// MARK: - Shared row chrome

/// A colored, rounded glyph chip for the sidebar — the System-Settings look this design
/// targets. Takes `SettingsSection.chipGlyph`/`chipColor` directly; `SkylightMenuCore` exposes
/// `chipColor` as the SwiftUI-free `SectionChipColor` token, so this view owns the one mapping
/// to an actual `Color`.
struct SectionChip: View {
    let glyph: LucideGlyph
    let color: SectionChipColor

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint)
            LucideIcon(glyph, size: 14)
                .foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }

    private var tint: Color {
        switch color {
        case .teal: return .teal
        case .gray: return .gray
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .green: return .green
        }
    }
}

/// The in-section "Advanced" disclosure: collapsed, last in its section, semantic text styles
/// (no fixed-pixel fonts — a Tahoe anti-pattern the redesign corrects).
///
/// Audit defect 3: vanilla SwiftUI `DisclosureGroup` on macOS only registers clicks on the
/// chevron glyph itself — clicking the "Advanced" / caption label does nothing, the opposite of
/// HIG disclosure-control convention and of how Finder/System Settings rows behave (whole row is
/// the hit target — developer.apple.com/design/human-interface-guidelines/disclosure-controls).
/// `.contentShape(Rectangle())` + `.onTapGesture` on the label makes the whole row toggle the same
/// `isExpanded` binding the chevron already drives; the chevron itself keeps working natively
/// since `DisclosureGroup` isn't otherwise touched. A pointing-hand cursor on hover makes the
/// row's clickability discoverable, matching the affordance macOS gives real buttons/links.
struct AdvancedDisclosure<Content: View>: View {
    @State private var isExpanded = false
    @ViewBuilder let content: Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("Advanced")
                    .font(.body)
                Text("Fine-tuning for specific setups.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }
}

// MARK: - Restart-pending banner (design §3.2)

/// Window-level, not per-row: one slim bar shown only while the shared `RestartCoordinator`
/// reports a pending restart, spanning every pane — Status included, where it's simply the same
/// banner rendered above that pane's own content. No live setter (fps/virtual display/
/// quit-on-disconnect) ever arms this; acknowledged restart-gated writes, including Video engine, arm it.
struct RestartBanner: View {
    var isBusy = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            LucideIcon(.refreshCW)
                .foregroundStyle(.secondary)
            Text("Some changes take effect after Moonwalk Host restarts.")
                .font(.subheadline)
            Spacer(minLength: 8)
            Button("Restart Now") { action() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Copy fix (audit defect 4): hand-written encoder-speed labels

/// `SoftwarePreset.label` (`SkylightMenuCore`) is `rawValue.capitalized`, which renders
/// "Veryfast"/"Ultrafast"/"Veryslow" — not real words. Rather than editing that Core type, this is
/// a hand-written display map layered on top via an extension in this (different) file/module
/// target, used everywhere the picker shows a preset. The stored `rawValue` — the x264 token
/// actually written to disk — is untouched.
extension SoftwarePreset {
    var displayLabel: String {
        switch self {
        case .ultrafast: return "Ultra fast"
        case .superfast: return "Super fast"
        case .veryfast: return "Very fast"
        case .faster: return "Faster"
        case .fast: return "Fast"
        case .medium: return "Medium"
        case .slow: return "Slow"
        case .slower: return "Slower"
        case .veryslow: return "Very slow"
        }
    }
}
