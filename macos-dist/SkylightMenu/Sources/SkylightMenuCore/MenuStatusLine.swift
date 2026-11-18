import Foundation

/// The connection phase half of `HostStatus` (which lives in the executable target's
/// `HostConnection.swift` and can't be imported here). A tiny mirror enum so
/// `MenuStatusLine.text` stays pure/testable without depending on any executable-target type --
/// `HostConnection.swift` bridges its own `HostStatus` to this via a small `menuPhase` computed
/// property.
public enum MenuHostPhase: Equatable, Sendable {
    case connecting
    case connected
    case offline
    case untrusted
}

/// The menu's one-line status row (Tahoe-native redesign §1.1/§5.1). Exact copy, worker-pastes,
/// does not invent: title case, real data, one line, no "healthy," no exclamation points. Full
/// `<duration> · <resolution><fps> · <codec> · <Mbps>` stays in `StatusLineFormatting` for the
/// Settings window's Status pane -- the menu line is deliberately shorter (resolution+fps+codec
/// only) so it fits at any menu width.
public enum MenuStatusLine {
    /// - Parameters:
    ///   - phase: the connection phase (`HostConnection.status.menuPhase`).
    ///   - streaming: `richStatus.streaming`.
    ///   - clientName: `richStatus.clientName` (empty = host hasn't reported one yet; falls back
    ///     to a generic "Streaming" lead rather than naming no one -- mirrors
    ///     `StatusPaneView.sessionHeadline`'s empty-`clientName` fallback).
    ///   - height: `richStatus.height` (0 = not yet known).
    ///   - fps: `richStatus.fps` (0 = not yet known).
    ///   - encoder: `richStatus.encoder` (raw value, e.g. "hevc"/"h264"/"av1"; unrecognized/empty
    ///     is omitted rather than guessed).
    public static func text(phase: MenuHostPhase, streaming: Bool, clientName: String, height: Int, fps: Int, encoder: String, resumable: Bool = false) -> String {
        switch phase {
        case .connecting: return "Starting Up…"
        case .offline: return "Not Running"
        case .untrusted: return "Can't Verify Moonwalk Host"
        case .connected:
            guard streaming else { return resumable ? "Ready to Resume" : "Ready" }
            var parts: [String] = []
            if height > 0 {
                let fpsSuffix = fps > 0 ? "\(fps)" : ""
                parts.append(StatusLineFormatting.resolutionBucket(height) + fpsSuffix)
            }
            if let codec = codecLabel(encoder) {
                parts.append(codec)
            }
            let lead = clientName.isEmpty ? "Streaming" : "Streaming to \(clientName)"
            return parts.isEmpty ? lead : lead + " · " + parts.joined(separator: " · ")
        }
    }

    /// Mirrors `ContentView`'s retired `codecLabel()` exactly (same recognized-value set, same
    /// "omit rather than guess" rule for anything else). Byte-identical output, now produced
    /// through `CodecLabelFormatStyle`'s native `FormatStyle` conformance.
    private static func codecLabel(_ encoder: String) -> String? {
        CodecLabelFormatStyle().format(encoder)
    }
}

/// `FormatStyle` conformance for the status line's codec half ("hevc"/"h265"→"HEVC", etc;
/// anything unrecognized is omitted rather than guessed). No built-in Foundation formatter knows
/// about encoder short-names, so the original switch is reproduced verbatim inside `format(_:)`.
/// `FormatOutput` is `String?` (not `String`) because "omit the codec entirely" is a valid,
/// load-bearing outcome here -- `FormatStyle` doesn't require a non-optional output.
public struct CodecLabelFormatStyle: FormatStyle {
    public init() {}
    public func format(_ encoder: String) -> String? {
        switch encoder.lowercased() {
        case "h264": return "H.264"
        case "hevc", "h265": return "HEVC"
        case "av1": return "AV1"
        default: return nil
        }
    }
}

public extension FormatStyle where Self == CodecLabelFormatStyle {
    /// Encoder short-name → display label ("hevc"/"h265" → "HEVC"), nil if unrecognized.
    static var codecLabel: CodecLabelFormatStyle { CodecLabelFormatStyle() }
}
