import Foundation

/// Every Lucide glyph the menu app draws. The raw value is the file name under `Lucide/svg` and
/// `Lucide/pdf` (macos-dist/SkylightMenu/Lucide), so adding a case without vendoring its file
/// fails `LucideGlyphTests`. Kept in `SkylightMenuCore` so state-to-glyph decisions stay testable.
public enum LucideGlyph: String, CaseIterable, Sendable {
    case activity
    case circle
    case circleCheck = "circle-check"
    case gauge
    case hourglass
    case laptopMinimal = "laptop-minimal"
    case link
    case monitor
    case monitorPlay = "monitor-play"
    case network
    case panelLeft = "panel-left"
    case refreshCW = "refresh-cw"
    case rotateCW = "rotate-cw"
    case triangleAlert = "triangle-alert"
    case userRoundPlus = "user-round-plus"
}
