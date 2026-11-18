import Foundation
import Testing
@testable import SkylightMenuCore

@Suite("PairedClient")
struct PairedClientTests {
    @Test("displayName uses name when present")
    func displayNameUsesNameWhenPresent() {
        let client = PairedClient(name: "Living Room PC", uuid: "abcd1234-5678-90ef-abcd-1234567890ef")
        #expect(client.displayName == "Living Room PC")
    }

    @Test("displayName falls back to short UUID when name blank")
    func displayNameFallsBackToShortUUIDWhenNameBlank() {
        let client = PairedClient(name: "", uuid: "abcd1234-5678-90ef-abcd-1234567890ef")
        #expect(client.displayName == "abcd1234")
    }

    /// Whitespace-only names must not print as a blank row either.
    @Test("displayName falls back to short UUID when name whitespace-only")
    func displayNameFallsBackToShortUUIDWhenNameWhitespaceOnly() {
        let client = PairedClient(name: "   ", uuid: "abcd1234-5678-90ef-abcd-1234567890ef")
        #expect(client.displayName == "abcd1234")
    }

    @Test("shortUUID takes first eight characters")
    func shortUUIDTakesFirstEightCharacters() {
        #expect(PairedClient.shortUUID("abcd1234-5678-90ef-abcd-1234567890ef") == "abcd1234")
    }

    @Test("shortUUID does not crash on short input")
    func shortUUIDDoesNotCrashOnShortInput() {
        #expect(PairedClient.shortUUID("ab") == "ab")
    }

    @Test("decodes from host JSON shape")
    func decodesFromHostJSONShape() throws {
        let json = """
        [{"name": "Living Room PC", "uuid": "abcd1234-5678-90ef-abcd-1234567890ef"}, {"name": "", "uuid": "beef0000"}]
        """
        let clients = try JSONDecoder().decode([PairedClient].self, from: Data(json.utf8))
        #expect(clients.count == 2)
        #expect(clients[0].displayName == "Living Room PC")
        #expect(clients[1].displayName == "beef0000")
        #expect(clients[0].id == clients[0].uuid)
    }
}
