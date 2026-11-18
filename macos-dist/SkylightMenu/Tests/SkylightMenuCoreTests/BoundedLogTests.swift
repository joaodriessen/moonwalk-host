import Foundation
import Testing
@testable import SkylightMenuCore

@Test func oversizedLogRotatesAndKeepsLiveFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = root.appendingPathComponent("host.log")
    try Data(repeating: 65, count: 32).write(to: log)
    try BoundedLog.rotateIfNeeded(log, maximumBytes: 16, generations: 3)
    #expect((try Data(contentsOf: log)).isEmpty)
    #expect((try Data(contentsOf: URL(fileURLWithPath: log.path + ".1"))).count == 32)
}

@Test func smallLogIsUntouched() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = root.appendingPathComponent("host.log")
    try Data("useful".utf8).write(to: log)
    try BoundedLog.rotateIfNeeded(log, maximumBytes: 16, generations: 3)
    #expect(try String(contentsOf: log, encoding: .utf8) == "useful")
}
