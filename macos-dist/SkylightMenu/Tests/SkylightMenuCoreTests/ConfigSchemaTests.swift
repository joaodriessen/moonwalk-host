import Foundation
import Testing
@testable import SkylightMenuCore

/// Check the schema format HostConnection decodes from the daemon's XPC reply.
@Suite("ConfigSchema decode")
struct ConfigSchemaTests {
    private let fixture = """
    {
        "version": 2,
        "options": [
            {
                "name": "stream_audio",
                "type": "bool",
                "default": true,
                "tab": "audio",
                "platform": ["macos", "linux"],
                "constraints": null
            },
            {
                "name": "minimum_fps_target",
                "type": "int",
                "default": 0,
                "tab": "vt",
                "platform": null,
                "constraints": {"min": 0, "max": 60}
            },
            {
                "name": "sw_preset",
                "type": "string",
                "default": "superfast",
                "tab": "sw",
                "platform": ["macos"],
                "constraints": {"enum": ["ultrafast", "superfast", "veryfast"]}
            }
        ],
        "discrepancies": [
            {"kind": "missing_on_platform", "options": ["av1_mode"], "detail": "not supported on this GPU"}
        ]
    }
    """

    private func decodeFixture() throws -> ConfigSchema {
        try JSONDecoder().decode(ConfigSchema.self, from: Data(fixture.utf8))
    }

    @Test("top-level fields decode")
    func topLevelFieldsDecode() throws {
        let schema = try decodeFixture()
        #expect(schema.version == 2)
        #expect(schema.options.count == 3)
        #expect(schema.discrepancies?.count == 1)
    }

    @Test("bool option decodes with default coding-key remap")
    func boolOptionDecodesWithDefaultCodingKeyRemap() throws {
        let schema = try decodeFixture()
        let option = try #require(schema.options.first { $0.name == "stream_audio" })
        #expect(option.type == "bool")
        #expect(option.defaultValue == .bool(true))
        #expect(option.tab == "audio")
        #expect(option.platform == ["macos", "linux"])
        #expect(option.constraints == nil)
    }

    @Test("numeric option decodes min/max constraints")
    func numericOptionDecodesMinMaxConstraints() throws {
        let schema = try decodeFixture()
        let option = try #require(schema.options.first { $0.name == "minimum_fps_target" })
        #expect(option.defaultValue == .int(0))
        #expect(option.platform == nil)
        #expect(option.constraints?.min == 0)
        #expect(option.constraints?.max == 60)
        #expect(option.constraints?.enumValues == nil)
    }

    /// The `enum` -> `enumValues` CodingKeys remap is the actual host-contract regression risk:
    /// `enum` is a Swift reserved word, so the field name must survive the rename round trip.
    @Test("enum-constrained option decodes enum coding-key remap")
    func enumConstrainedOptionDecodesEnumCodingKeyRemap() throws {
        let schema = try decodeFixture()
        let option = try #require(schema.options.first { $0.name == "sw_preset" })
        #expect(option.defaultValue == .string("superfast"))
        #expect(option.constraints?.enumValues == ["ultrafast", "superfast", "veryfast"])
        #expect(option.constraints?.min == nil)
    }

    @Test("discrepancy entry decodes")
    func discrepancyEntryDecodes() throws {
        let schema = try decodeFixture()
        let discrepancy = try #require(schema.discrepancies?.first)
        #expect(discrepancy.kind == "missing_on_platform")
        #expect(discrepancy.options == ["av1_mode"])
        #expect(discrepancy.detail == "not supported on this GPU")
    }

    @Test("Identifiable id mirrors name")
    func identifiableIdMirrorsName() throws {
        let schema = try decodeFixture()
        let option = try #require(schema.options.first { $0.name == "stream_audio" })
        #expect(option.id == option.name)
    }
}
