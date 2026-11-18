import Foundation

public struct CaptureDisplay: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
    public static func options(_ displays: [CaptureDisplay], selected: String) -> [CaptureDisplay] {
        var options = [CaptureDisplay(id: "", name: "Automatic (main display)")]
        options += displays.filter { !$0.id.isEmpty }
        if !selected.isEmpty, !options.contains(where: { $0.id == selected }) {
            options.append(CaptureDisplay(id: selected, name: "Unavailable display (\(selected))"))
        }
        return options
    }
}
