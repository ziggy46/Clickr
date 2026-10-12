import Testing
@testable import BigInt

@Test func moduleLinks() {
    #expect(String(describing: BigIntModule.self) == "BigIntModule")
}
