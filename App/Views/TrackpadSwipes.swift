import AppKit
import Session
import SwiftUI

/// Two-finger swipes on the trackpad, while the pointer is over the clickpad, become touches
/// on the Apple TV's remote touch surface, like swiping on a Siri Remote. The TV adds its
/// own momentum from how fast the swipe ended, so the Mac's momentum events are dropped.
/// Ordinary mouse wheels (no gesture phases) are left alone.
struct TrackpadSwipes: ViewModifier {
    let model: RemoteViewModel
    let isEnabled: Bool
    @State private var catcher = SwipeCatcher()

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                if case .active = phase { catcher.isHovering = true } else { catcher.isHovering = false }
            }
            .onAppear { update() }
            .onChange(of: isEnabled) { update() }
            .onDisappear { catcher.stop() }
    }

    private func update() {
        if isEnabled {
            catcher.start { [model] events in model.touch(events) }
        } else {
            catcher.stop()
        }
    }
}

@MainActor
private final class SwipeCatcher {
    var isHovering = false
    private var gesture = TouchpadGesture()
    private var monitor: Any?
    private var send: (([TouchEvent]) -> Void)?

    func start(sending send: @escaping ([TouchEvent]) -> Void) {
        self.send = send
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        send?(gesture.end())
        send = nil
    }

    /// Returns whether the event was used (and so shouldn't scroll anything else).
    private func handle(_ event: NSEvent) -> Bool {
        // Momentum after the fingers lift: the TV does its own.
        if !event.momentumPhase.isEmpty { return gesture.isTouching || isHovering }
        guard !event.phase.isEmpty, event.hasPreciseScrollingDeltas else { return false }
        // A swipe has to start over the clickpad, but can carry on outside it.
        guard isHovering || gesture.isTouching else { return false }

        if event.phase.contains(.began) {
            send?(gesture.begin())
        } else if event.phase.contains(.changed) {
            let travel = TouchpadGesture.fingerTravel(
                scrollingDeltaX: event.scrollingDeltaX,
                scrollingDeltaY: event.scrollingDeltaY,
                directionInverted: event.isDirectionInvertedFromDevice
            )
            send?(gesture.move(dx: travel.dx, dy: travel.dy))
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            send?(gesture.end())
        }
        return true
    }
}
