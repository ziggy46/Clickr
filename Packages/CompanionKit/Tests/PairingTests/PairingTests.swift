import Testing
@testable import Pairing

@Test func moduleLinks() {
    #expect(String(describing: PairingModule.self) == "PairingModule")
}
