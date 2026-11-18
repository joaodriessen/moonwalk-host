import Testing
@testable import SkylightMenuCore

@Test func unavailableDeviceListPreservesLastGoodAndDistinguishesRealEmpty() {
    var list = RemoteList<String>()
    #expect(!list.hasValue)
    list.receive(nil)
    #expect(list.phase == .unavailable)
    #expect(!list.hasValue)
    list.receive(["trusted device"])
    list.receive(nil)
    #expect(list.values == ["trusted device"])
    #expect(list.hasValue)
    #expect(list.phase == .unavailable)
    list.receive([])
    #expect(list.phase == .available)
    #expect(list.hasValue)
    #expect(list.values.isEmpty)
}
