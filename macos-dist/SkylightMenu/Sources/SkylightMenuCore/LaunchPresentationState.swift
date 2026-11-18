public struct LaunchPresentationState: Equatable, Sendable {
    private var evaluated = false

    public init() {}

    public mutating func shouldOpenWelcome(setupComplete: Bool) -> Bool {
        guard !evaluated else { return false }
        evaluated = true
        return !setupComplete
    }
}
