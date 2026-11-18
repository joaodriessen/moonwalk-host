import Observation

@MainActor @Observable
public final class QuitConfirmation {
    public var isPresented = false
    private var action: (@MainActor () -> Void)?
    public init() {}

    public func request(streaming: Bool, stateKnown: Bool, quit: @escaping @MainActor () -> Void) {
        if streaming || !stateKnown {
            action = quit
            isPresented = true
        } else { cancel(); quit() }
    }

    public func cancel() { isPresented = false; action = nil }
    public func confirm() {
        let quit = action
        cancel()
        quit?()
    }
}
