import Testing
@testable import Session

@Suite struct TouchpadGestureTests {
    @Test func swipeStartsInTheMiddleAndFollowsTheFingers() {
        var gesture = TouchpadGesture(scale: 2)
        #expect(gesture.begin() == [TouchEvent(.press, x: 500, y: 500)])
        #expect(gesture.move(dx: 50, dy: -25) == [TouchEvent(.hold, x: 600, y: 450)])
        #expect(gesture.end() == [TouchEvent(.release, x: 600, y: 450)])
        #expect(!gesture.isTouching)
        #expect(gesture.end().isEmpty)
    }

    @Test func moveWithoutBeginPressesFirst() {
        var gesture = TouchpadGesture(scale: 1)
        #expect(gesture.move(dx: 10, dy: 0) == [TouchEvent(.press, x: 500, y: 500), TouchEvent(.hold, x: 510, y: 500)])
    }

    @Test func runningOffTheEdgeStartsAgainInTheMiddle() {
        var gesture = TouchpadGesture(scale: 1)
        _ = gesture.begin()
        #expect(gesture.move(dx: 600, dy: 0) == [
            TouchEvent(.hold, x: 1000, y: 500),
            TouchEvent(.release, x: 1000, y: 500),
            TouchEvent(.press, x: 500, y: 500),
        ])
        #expect(gesture.move(dx: 0, dy: 10) == [TouchEvent(.hold, x: 500, y: 510)])
    }

    @Test func fingerTravelFollowsTheScrollDirectionSetting() {
        // Natural scrolling: the deltas already point the way the fingers moved.
        let natural = TouchpadGesture.fingerTravel(scrollingDeltaX: 3, scrollingDeltaY: -4, directionInverted: true)
        #expect(natural.dx == 3 && natural.dy == -4)
        let classic = TouchpadGesture.fingerTravel(scrollingDeltaX: 3, scrollingDeltaY: -4, directionInverted: false)
        #expect(classic.dx == -3 && classic.dy == 4)
    }
}
