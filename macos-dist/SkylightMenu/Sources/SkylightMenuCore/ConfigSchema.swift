import Foundation

/// S2 schema-driven long-tail model (docs/design/menubar-app.md "S2", docs/design/
/// config-schema-ssot.md). Decodes the SAME `config_schema.json` the host's `getConfigSchema`
/// XPC call and `confighttp.cpp`'s `GET /api/configSchema` both serve verbatim -- this file is a
/// pure data model, no parallel option list. See `SettingsView.swift` for the generated form.
///
/// Lives in `SkylightMenuCore` (not the `SkylightMenu` executable target) so it can be unit
/// tested in isolation. `public` throughout so the executable target (which owns
/// `HostConnection`'s live decode call) can see it.

/// A JSON value of unknown shape, used for `ConfigOption.defaultValue` (which is a bool, number,
/// string, array, or object depending on the option -- `dd_mode_remapping`/`global_prep_cmd`/
/// `keybindings` are `object`/`list`/`map`) and, more rarely, echoed back for opaque advanced
/// values. Never interpreted beyond `displayString` -- rendering/validation always happens
/// against the *live* string value from `getConfigValues`, matching how `sunshine.conf` itself
/// stores every value as text.
public enum JSONValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported config_schema.json value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Stringified for display, and as the fallback *initial* value when the live
    /// `getConfigValues` bag doesn't have this key yet (host has never written it, so the
    /// C++-side default applies). Bools render as `"enabled"`/`"disabled"` -- the same
    /// truthy/falsy vocabulary `sunshine.conf` itself uses (see `config_validate.cpp`'s
    /// `try_parse_bool`), NOT Swift's `"true"`/`"false"`, so a fallback default round-trips
    /// through `setConfigValue` cleanly if the user never touches the field.
    public var displayString: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .double(let value):
            // Whole-number doubles (e.g. minimum_fps_target's default `0`) display without a
            // trailing ".0" -- matches how the web UI's number inputs show config values.
            if value == value.rounded() { return String(Int(value)) }
            return String(value)
        case .bool(let value): return value ? "enabled" : "disabled"
        case .array, .object:
            if let data = try? JSONEncoder().encode(self), let text = String(data: data, encoding: .utf8) {
                return text
            }
            return ""
        case .null: return ""
        }
    }
}

/// One option from `config_schema.json`'s `options[]` -- name/type/default/tab/platform/
/// constraints. Mirrors `docs/design/config-schema-ssot.md`'s field set exactly; nothing added.
public struct ConfigOption: Codable, Identifiable, Equatable {
    public var id: String { name }

    public let name: String
    public let type: String
    public let defaultValue: JSONValue?
    public let tab: String
    public let platform: [String]?
    public let constraints: Constraints?

    public struct Constraints: Codable, Equatable {
        public let min: Double?
        public let max: Double?
        public let enumValues: [String]?

        public enum CodingKeys: String, CodingKey {
            case min, max
            case enumValues = "enum"
        }
    }

    public enum CodingKeys: String, CodingKey {
        case name, type, tab, platform, constraints
        case defaultValue = "default"
    }
}

/// The full parsed `config_schema.json` document. Kept as a pure decode target for
/// `HostConnection.applyConfigSchema` -- the hand-authored `SettingsCatalog.swift` presentation
/// layer (docs/design/settings-ux.md) is the source of truth for WHICH options surface and how;
/// this struct no longer derives a generic tab-grouped or platform-filtered view of the schema
/// (the retired `ConfigTabMeta`/`optionsByTab`/`namesHiddenOnMacOS`/`visibleOptions` -- see git
/// history if a future generic fallback renderer is ever needed again).
public struct ConfigSchema: Codable {
    public let version: Int?
    public let options: [ConfigOption]
    public let discrepancies: [Discrepancy]?

    public struct Discrepancy: Codable {
        public let kind: String
        public let options: [String]
        public let detail: String?
    }
}
