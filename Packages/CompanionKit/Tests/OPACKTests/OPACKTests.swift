import Testing
@testable import OPACK

@Test func moduleLinks() {
    #expect(String(describing: OPACKModule.self) == "OPACKModule")
}
