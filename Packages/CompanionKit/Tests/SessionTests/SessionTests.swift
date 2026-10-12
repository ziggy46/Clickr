import Testing
@testable import Session

@Test func moduleLinks() {
    #expect(String(describing: SessionModule.self) == "SessionModule")
}
