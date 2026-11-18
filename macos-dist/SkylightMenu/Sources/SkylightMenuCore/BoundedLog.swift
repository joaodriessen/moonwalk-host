import Foundation

public enum BoundedLog {
    /// Snapshot up to the last maximumBytes without rotating or reading a concurrently growing
    /// file to EOF. Remove only leading UTF-8 continuation bytes split by the byte boundary.
    public static func utf8Tail(_ url: URL, maximumBytes: Int = 1_048_576) throws -> String {
        guard maximumBytes > 0 else { return "" }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        let count = min(UInt64(maximumBytes), end)
        try handle.seek(toOffset: end - count)
        let data = try handle.read(upToCount: Int(count)) ?? Data()
        let aligned = data.drop(while: { $0 & 0xC0 == 0x80 })
        return String(decoding: aligned, as: UTF8.self)
    }

    public static func rotateIfNeeded(
        _ url: URL,
        maximumBytes: UInt64 = 8 * 1024 * 1024,
        generations: Int = 3,
        files: FileManager = .default
    ) throws {
        guard generations > 0,
              let attributes = try? files.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value > maximumBytes else { return }

        for generation in stride(from: generations, through: 2, by: -1) {
            let older = URL(fileURLWithPath: url.path + ".\(generation - 1)")
            let newer = URL(fileURLWithPath: url.path + ".\(generation)")
            if files.fileExists(atPath: newer.path) { try files.removeItem(at: newer) }
            if files.fileExists(atPath: older.path) { try files.moveItem(at: older, to: newer) }
        }
        let first = URL(fileURLWithPath: url.path + ".1")
        if files.fileExists(atPath: first.path) { try files.removeItem(at: first) }
        try files.copyItem(at: url, to: first)

        // Copy-then-truncate keeps an existing writer's file descriptor valid.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.close()
    }
}
