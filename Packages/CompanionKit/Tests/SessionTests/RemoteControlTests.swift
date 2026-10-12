import Testing
@testable import Session

@Test func hidCodesMatchPyatv() {
    let expected: [RemoteButton: Int] = [
        .up: 1, .down: 2, .left: 3, .right: 4, .menu: 5, .select: 6,
        .home: 7, .volumeUp: 8, .volumeDown: 9, .playPause: 14,
    ]
    for button in RemoteButton.allCases {
        #expect(button.hidCode == expected[button])
    }
}
