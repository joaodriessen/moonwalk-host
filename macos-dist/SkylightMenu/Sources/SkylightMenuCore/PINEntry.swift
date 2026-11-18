import Foundation

/// Empty positions stay in place while editing; an incomplete PIN is never submitted.
public struct PINEntry: Equatable {
    public private(set) var slots = Array(repeating: "", count: 4)
    public init() {}
    public var pin: String { slots.allSatisfy { $0.count == 1 } ? slots.joined() : "" }
    public mutating func replace(at index: Int, with input: String) {
        guard slots.indices.contains(index) else { return }
        let digits = input.filter { $0.isASCII && $0.isNumber }
        if digits.count > 1 {
            slots = Array(repeating: "", count: 4)
            for (offset, digit) in digits.prefix(4).enumerated() { slots[offset] = String(digit) }
        } else { slots[index] = digits }
    }
}
