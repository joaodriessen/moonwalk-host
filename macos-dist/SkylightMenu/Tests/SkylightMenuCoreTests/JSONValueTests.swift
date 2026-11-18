import Foundation
import Testing
@testable import SkylightMenuCore

@Suite("JSONValue")
struct JSONValueTests {
    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test("decodes bool")
    func decodesBool() throws {
        #expect(try decode("true") == .bool(true))
        #expect(try decode("false") == .bool(false))
    }

    @Test("decodes int")
    func decodesInt() throws {
        #expect(try decode("42") == .int(42))
    }

    @Test("decodes double")
    func decodesDouble() throws {
        #expect(try decode("3.5") == .double(3.5))
    }

    @Test("decodes string")
    func decodesString() throws {
        #expect(try decode("\"hello\"") == .string("hello"))
    }

    @Test("decodes array")
    func decodesArray() throws {
        #expect(try decode("[1, 2, 3]") == .array([.int(1), .int(2), .int(3)]))
    }

    @Test("decodes object")
    func decodesObject() throws {
        #expect(try decode("{\"a\": 1}") == .object(["a": .int(1)]))
    }

    @Test("decodes null")
    func decodesNull() throws {
        #expect(try decode("null") == .null)
    }

    // MARK: - displayString

    @Test("displayString: whole-number double has no trailing zero")
    func displayStringWholeNumberDoubleHasNoTrailingZero() {
        #expect(JSONValue.double(60.0).displayString == "60")
    }

    @Test("displayString: fractional double keeps decimal")
    func displayStringFractionalDoubleKeepsDecimal() {
        #expect(JSONValue.double(3.5).displayString == "3.5")
    }

    @Test("displayString: bool uses truthy vocabulary, not Swift bool")
    func displayStringBoolUsesTruthyVocabularyNotSwiftBool() {
        #expect(JSONValue.bool(true).displayString == "enabled")
        #expect(JSONValue.bool(false).displayString == "disabled")
    }

    @Test("displayString: string and int pass through")
    func displayStringStringAndIntPassThrough() {
        #expect(JSONValue.string("x264").displayString == "x264")
        #expect(JSONValue.int(30).displayString == "30")
    }

    @Test("displayString: array reserializes as JSON text")
    func displayStringArrayReserializesAsJSONText() {
        let text = JSONValue.array([.int(1), .int(2)]).displayString
        #expect(text == "[1,2]")
    }

    @Test("displayString: null is empty")
    func displayStringNullIsEmpty() {
        #expect(JSONValue.null.displayString == "")
    }
}
