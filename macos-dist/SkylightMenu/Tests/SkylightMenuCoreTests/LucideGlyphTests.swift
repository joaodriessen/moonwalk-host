import Foundation
import Testing
@testable import SkylightMenuCore

@Suite("LucideGlyph")
struct LucideGlyphTests {
    /// macos-dist/SkylightMenu, found from this file so the check runs from any working directory.
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("every glyph is vendored as SVG and generated as PDF")
    func everyGlyphIsVendored() {
        for glyph in LucideGlyph.allCases {
            for (folder, ext) in [("svg", "svg"), ("pdf", "pdf")] {
                let file = Self.packageRoot.appendingPathComponent("Lucide/\(folder)/\(glyph.rawValue).\(ext)")
                #expect(FileManager.default.fileExists(atPath: file.path), "missing \(file.path)")
            }
        }
    }

    @Test("no file is vendored without a glyph")
    func noUnusedFiles() throws {
        let folder = Self.packageRoot.appendingPathComponent("Lucide/svg")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".svg") }.map { String($0.dropLast(4)) }
        #expect(Set(names) == Set(LucideGlyph.allCases.map(\.rawValue)))
    }
}
