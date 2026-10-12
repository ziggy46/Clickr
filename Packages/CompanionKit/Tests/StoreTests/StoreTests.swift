import Testing
@testable import Store

@Test func moduleLinks() {
    #expect(String(describing: StoreModule.self) == "StoreModule")
}
