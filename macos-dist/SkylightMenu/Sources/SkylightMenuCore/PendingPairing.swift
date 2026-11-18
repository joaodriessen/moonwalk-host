import Foundation

/// S3 pairing-DoS/hijack fix, Layer B: one ELIGIBLE pending pairing session, mirroring
/// `nvhttp::list_pending_pair_sessions()`'s JSON shape (`{"uniqueid", "source_ip", "age_sec"}`,
/// src/nvhttp.cpp). `source_ip` is the attacker-unspoofable label `PairingSheet.swift`'s picker
/// shows the owner -- see `pair_session_t::source_ip`'s doc comment (nvhttp.h) for why it can't
/// be forged. `Identifiable` by `uniqueid` so the picker can drive a `List`/`ForEach` directly.
///
/// Moved into `SkylightMenuCore` (design-pairing-statemachine.md §1) from
/// `HostConnection.swift` so the pure `PairingState`/`PairingReducer` can reference it without
/// depending on the `SkylightMenu` executable target -- pure `Codable` value data, no XPC/UI
/// concerns, so the move is mechanical (no behavior change).
public struct PendingPairing: Codable, Identifiable, Equatable, Sendable {
    public var uniqueid: String
    public var sourceIp: String
    public var ageSec: Int
    /// Best-effort, UNTRUSTED reverse-DNS label for `sourceIp` -- empty when unresolved or
    /// unavailable (the host does an async, never-blocking lookup; see
    /// `nvhttp::list_pending_pair_sessions()`'s doc comment, src/nvhttp.cpp). Spoofable by
    /// anything with a PTR record for that address -- `sourceIp` remains the actual
    /// security-relevant identifier; this exists purely as a human-legible hint so the owner
    /// doesn't have to parse/click a bare IP. Defaults to "" so older host builds that don't yet
    /// send this key still decode successfully.
    public var hostnameHint: String = ""
    /// Best-effort, UNTRUSTED label the connecting CLIENT itself sent (the pairing request's
    /// `devicename` param -- see `pair_session_t::client_device_name`'s doc comment, src/nvhttp.h,
    /// and `nvhttp::list_pending_pair_sessions()`'s `"client_name"` key, src/nvhttp.cpp).
    /// Attacker-controllable exactly like `hostnameHint`, and used the SAME way: display-only
    /// input to pre-fill the owner's EDITABLE device-name field (`PairingReducer`'s
    /// `.deviceSelected` case) -- never a trust signal, never part of the picker's identity
    /// labeling (`PairingSheet.swift`'s rows stay `sourceIp`/`hostnameHint`-based, unchanged).
    /// Defaults to "" so older host builds that don't yet send this key still decode successfully.
    public var clientName: String = ""

    public var id: String { uniqueid }

    enum CodingKeys: String, CodingKey {
        case uniqueid
        case sourceIp = "source_ip"
        case ageSec = "age_sec"
        case hostnameHint = "hostname_hint"
        case clientName = "client_name"
    }

    public init(uniqueid: String, sourceIp: String, ageSec: Int, hostnameHint: String = "", clientName: String = "") {
        self.uniqueid = uniqueid
        self.sourceIp = sourceIp
        self.ageSec = ageSec
        self.hostnameHint = hostnameHint
        self.clientName = clientName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uniqueid = try container.decode(String.self, forKey: .uniqueid)
        sourceIp = try container.decode(String.self, forKey: .sourceIp)
        ageSec = try container.decode(Int.self, forKey: .ageSec)
        // Decoded leniently (defaults to "") rather than required, so a pending-pairings response
        // from a host build that predates this field doesn't fail the WHOLE decode over one
        // missing, purely-cosmetic key.
        hostnameHint = try container.decodeIfPresent(String.self, forKey: .hostnameHint) ?? ""
        clientName = try container.decodeIfPresent(String.self, forKey: .clientName) ?? ""
    }

    // MARK: - Display-only derived values (owner: "without the .local after it")
    //
    // Neither of these is ever a trust signal or a selection key -- `uniqueid` is the only
    // selection key and `sourceIp` remains the only security-relevant identifier (see this
    // struct's doc comment and `hostnameHint`'s own doc comment above: a reverse-DNS hint is
    // spoofable by anything with a PTR record for the address; the source IP of a completed TCP
    // getservercert exchange is not). These exist purely so the owner sees a name instead of a
    // bare IP in the picker.

    /// `hostnameHint` with a trailing mDNS/Bonjour ".local" suffix stripped for display. Empty
    /// when `hostnameHint` is empty (no hint to strip).
    public var displayHostname: String {
        guard hostnameHint.hasSuffix(".local") else { return hostnameHint }
        return String(hostnameHint.dropLast(".local".count))
    }

    /// `clientName` with a trailing mDNS/Bonjour ".local" suffix stripped and whitespace trimmed,
    /// for use as the pairing sheet's editable device-name FIELD DEFAULT ONLY (see
    /// `PairingReducer`'s `.deviceSelected` case) -- never for the picker's identity labeling,
    /// which stays `sourceIp`/`displayHostname`-based. Empty when `clientName` is empty OR is the
    /// literal `"roth"` -- stock Moonlight/GFE clients (and Starlight before this feature) send
    /// exactly that hardcoded legacy sentinel as `devicename`, never a real hostname, so surfacing
    /// it verbatim would replace a genuinely informative reverse-DNS `displayHostname` guess with
    /// a meaningless word. Treating it as empty lets `PairingReducer.deviceSelected`'s existing
    /// fallback chain (client name -> `displayHostname` -> empty) do the right thing automatically.
    public var displayClientName: String {
        var name = clientName
        if name.hasSuffix(".local") {
            name = String(name.dropLast(".local".count))
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name == "roth" ? "" : name
    }

    /// "friendly-name · IP" when a hint is present, else the IP alone -- the single formatting
    /// rule shared by the pending-list row and the verifying/waiting label, so both read the same
    /// device the same way.
    public var displayLabel: String {
        displayHostname.isEmpty ? sourceIp : "\(displayHostname) · \(sourceIp)"
    }
}
