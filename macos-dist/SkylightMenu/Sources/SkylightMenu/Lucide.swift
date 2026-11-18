import AppKit
import SkylightMenuCore
import SwiftUI

/// Loads the vendored Lucide glyphs (macos-dist/SkylightMenu/Lucide) as template images, so
/// AppKit and SwiftUI tint them like SF Symbols: menu bar, selection, vibrancy, dark mode and
/// Increase Contrast. They ship as vector PDF in Contents/Resources/Lucide, copied there by
/// scripts/package-release.sh; PDF is the one vector format NSImage loads on every macOS this
/// app supports. Debug `swift run`/`swift test` have no app bundle, so they read the source tree;
/// release builds leave that path out, since verify-artifact.sh rejects a build path in the app.
enum Lucide {
    @MainActor private static var cache: [LucideGlyph: NSImage] = [:]

    #if DEBUG
    private static let sourceFolder: URL? = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Lucide/pdf")
    #else
    private static let sourceFolder: URL? = nil
    #endif

    static func url(for glyph: LucideGlyph) -> URL? {
        let file = "\(glyph.rawValue).pdf"
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Lucide/\(file)"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        guard let source = sourceFolder?.appendingPathComponent(file) else { return nil }
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    /// A template image `points` square. A missing file draws nothing rather than crashing the
    /// menu; LucideGlyphTests and test-app-layout.sh keep that from shipping.
    @MainActor static func image(_ glyph: LucideGlyph, points: CGFloat = 24) -> NSImage {
        let base: NSImage
        if let cached = cache[glyph] {
            base = cached
        } else {
            base = url(for: glyph).flatMap(NSImage.init(contentsOf:)) ?? NSImage(size: NSSize(width: 24, height: 24))
            base.isTemplate = true
            cache[glyph] = base
        }
        guard base.size.width != points else { return base }
        let sized = base.copy() as! NSImage
        sized.size = NSSize(width: points, height: points)
        sized.isTemplate = true
        return sized
    }
}

/// A Lucide glyph in SwiftUI, sized in points like an SF Symbol of the same visual weight:
/// 16 beside body text, 18 in the menu bar, larger for heroes. Takes `.foregroundStyle`.
struct LucideIcon: View {
    let glyph: LucideGlyph
    var size: CGFloat = 16

    init(_ glyph: LucideGlyph, size: CGFloat = 16) {
        self.glyph = glyph
        self.size = size
    }

    var body: some View {
        Image(nsImage: Lucide.image(glyph, points: size))
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension Label where Title == Text, Icon == LucideIcon {
    /// `Label(_:systemImage:)` for a Lucide glyph.
    @MainActor init(_ title: String, lucide glyph: LucideGlyph, size: CGFloat = 16) {
        self.init { Text(title) } icon: { LucideIcon(glyph, size: size) }
    }
}
