import Testing
@testable import SkylightMenuCore

@Suite("ConfigBool")
struct ConfigBoolTests {
    @Test("truthy vocabulary is case-insensitive")
    func truthyVocabularyCaseInsensitive() {
        for raw in ["enabled", "true", "yes", "on", "1", "ENABLED", "True", "YES", "On"] {
            #expect(ConfigBool.isOn(raw, default: false), "\(raw) should read as on")
        }
    }

    /// Any non-empty string outside the truthy vocabulary reads as off -- `default` is only
    /// consulted when `raw` is `nil`/empty (see `nilOrEmptyFallsBackToDefault`), NOT as a
    /// fallback for an unrecognized non-empty value.
    @Test("falsy or unrecognized non-empty strings read as off regardless of default")
    func falsyOrUnrecognizedNonEmptyStringsReadAsOffRegardlessOfDefault() {
        #expect(!ConfigBool.isOn("disabled", default: false))
        #expect(!ConfigBool.isOn("disabled", default: true))
        #expect(!ConfigBool.isOn("nonsense", default: false))
        #expect(!ConfigBool.isOn("nonsense", default: true))
    }

    @Test("nil or empty falls back to default")
    func nilOrEmptyFallsBackToDefault() {
        #expect(ConfigBool.isOn(nil, default: true))
        #expect(!ConfigBool.isOn(nil, default: false))
        #expect(ConfigBool.isOn("", default: true))
        #expect(!ConfigBool.isOn("", default: false))
    }

    @Test("string round trip")
    func stringRoundTrip() {
        #expect(ConfigBool.string(true) == "enabled")
        #expect(ConfigBool.string(false) == "disabled")
        #expect(ConfigBool.isOn(ConfigBool.string(true), default: false))
        #expect(!ConfigBool.isOn(ConfigBool.string(false), default: true))
    }
}
