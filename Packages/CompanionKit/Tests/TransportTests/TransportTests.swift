import Testing
@testable import Transport

@Test func moduleLinks() {
    #expect(String(describing: TransportModule.self) == "TransportModule")
}
