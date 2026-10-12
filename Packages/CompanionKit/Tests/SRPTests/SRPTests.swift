import Testing
@testable import SRP

@Test func moduleLinks() {
    #expect(String(describing: SRPModule.self) == "SRPModule")
}
