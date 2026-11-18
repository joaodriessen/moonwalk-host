import Testing
@testable import SkylightMenuCore

@Suite("SettingsSection")
struct SettingsSectionTests {
    /// The owner-amended IA: five sections, Status first -- NOT the design doc's 4-content-section
    /// merge (Display/Devices stay split; Quality+Sound collapse into one `streaming` section).
    /// The former standalone `general` section was folded into `status`.
    @Test("five sections, Status first")
    func fiveSectionsStatusFirst() {
        #expect(
            SettingsSection.allCases == [.status, .streaming, .display, .devices, .network]
        )
    }

    @Test("titles are human-readable")
    func titlesAreHumanReadable() {
        #expect(SettingsSection.status.title == "Status")
        #expect(SettingsSection.streaming.title == "Streaming")
        #expect(SettingsSection.display.title == "Display")
        #expect(SettingsSection.devices.title == "Devices")
        #expect(SettingsSection.network.title == "Network")
    }

    /// Every section has a distinct id (used as the `List` selection tag / `Identifiable`
    /// conformance) -- a collision would make two sidebar rows indistinguishable to SwiftUI.
    @Test("every id is unique")
    func everyIDIsUnique() {
        let ids = SettingsSection.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// Chip color is static per section (identity, not state) -- every section must resolve to
    /// exactly one color, and no two adjacent-in-sidebar sections should be visually identical.
    @Test("every section has a distinct chip color")
    func everySectionHasADistinctChipColor() {
        let colors = SettingsSection.allCases.map(\.chipColor)
        #expect(Set(colors).count == colors.count, "every section should have a visually distinct chip color")
    }

    @Test("every section has a distinct chip glyph")
    func everySectionHasADistinctChipGlyph() {
        let glyphs = SettingsSection.allCases.map(\.chipGlyph)
        #expect(Set(glyphs).count == glyphs.count)
    }
}
