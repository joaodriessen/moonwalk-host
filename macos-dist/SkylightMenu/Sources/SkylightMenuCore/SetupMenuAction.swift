public enum SetupMenuAction {
    public static func title(setupComplete: Bool, pendingPairing: Bool) -> String {
        guard setupComplete else { return "Finish Setup…" }
        return pendingPairing ? "Pair New Device… •" : "Pair New Device…"
    }
}
