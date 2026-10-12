import Testing
@testable import Discovery

@Test func moduleLinks() {
    #expect(String(describing: DiscoveryModule.self) == "DiscoveryModule")
}
