import Foundation

/// One `_hidT` touch on the Siri Remote's touch surface, a 1000 x 1000 pad (pyatv's
/// TOUCHPAD_WIDTH and TOUCHPAD_HEIGHT) with y growing downwards.
public struct TouchEvent: Sendable, Equatable {
    /// pyatv's TouchAction values. A move is sent as Hold.
    public enum Phase: Int, Sendable {
        case press = 1
        case hold = 3
        case release = 4
    }

    public let phase: Phase
    public let x: Int
    public let y: Int

    public init(_ phase: Phase, x: Int, y: Int) {
        self.phase = phase
        self.x = x
        self.y = y
    }
}

/// Turns a two-finger swipe on a Mac trackpad into touches on the remote's pad. A swipe
/// starts in the middle of the pad, like a thumb resting on the remote, and moves with the
/// fingers. Long swipes that would run off the edge lift the "thumb" and put it back in the
/// middle, so the TV keeps moving the way it does when you swipe again on the real remote.
public struct TouchpadGesture: Sendable {
    public static let size = 1000.0
    static let center = size / 2

    /// Pad units per point of finger travel. A 200 pt swipe crosses half the pad.
    public var scale: Double

    private var position: (x: Double, y: Double)?

    public init(scale: Double = 2.5) {
        self.scale = scale
    }

    public var isTouching: Bool { position != nil }

    /// Fingers down on the trackpad.
    public mutating func begin() -> [TouchEvent] {
        var events: [TouchEvent] = []
        if position != nil { events += end() }
        position = (Self.center, Self.center)
        events.append(event(.press))
        return events
    }

    /// Fingers moved by (dx, dy) points, with y growing downwards.
    public mutating func move(dx: Double, dy: Double) -> [TouchEvent] {
        var events: [TouchEvent] = []
        if position == nil { events += begin() }
        guard var current = position else { return events }
        current.x += dx * scale
        current.y += dy * scale
        let range = 0...Self.size
        if range.contains(current.x), range.contains(current.y) {
            position = current
            events.append(event(.hold))
        } else {
            // Ran off the pad: finish the swipe at the edge and start again in the middle.
            position = (min(max(current.x, 0), Self.size), min(max(current.y, 0), Self.size))
            events.append(event(.hold))
            events.append(event(.release))
            position = (Self.center, Self.center)
            events.append(event(.press))
        }
        return events
    }

    /// Fingers lifted (or the swipe was cancelled).
    public mutating func end() -> [TouchEvent] {
        guard position != nil else { return [] }
        let release = event(.release)
        position = nil
        return [release]
    }

    /// Finger travel from a scroll event's deltas. AppKit reports how the content should
    /// move, which with natural scrolling is the way the fingers went and otherwise the
    /// opposite.
    public static func fingerTravel(scrollingDeltaX: Double, scrollingDeltaY: Double, directionInverted: Bool) -> (dx: Double, dy: Double) {
        let sign = directionInverted ? 1.0 : -1.0
        return (scrollingDeltaX * sign, scrollingDeltaY * sign)
    }

    private func event(_ phase: TouchEvent.Phase) -> TouchEvent {
        let point = position ?? (Self.center, Self.center)
        return TouchEvent(phase, x: Int(point.x.rounded()), y: Int(point.y.rounded()))
    }
}
