import AppKit
import CoreGraphics

/// Routes ball-scroll by direction while the device is in scroll mode.
///
/// In scroll mode the ball sends real scroll-wheel events, proportional to how
/// far it turned. Each roll direction can either pass through — the smooth
/// native scrolling that is the whole point of scroll mode — or accumulate
/// toward a discrete action such as switching desktops.
///
/// The tap is **disabled entirely when no direction is assigned**, which is the
/// default. A tap sits in the delivery path of every event it asks for, so
/// leaving it enabled to do nothing would put every scroll in the system
/// through this process for no reason.
final class WheelRouter: @unchecked Sendable {
    private let snapshot: SnapshotBox
    private let runner: ActionRunner

    private var tap: CFMachPort?
    private var enabled = false

    // Touched only on the tap thread.
    private var accumulated: Double = 0
    private var accumulatedFor: Direction?
    private var lastEventAt: TimeInterval = 0
    private var lastFireAt: TimeInterval = 0

    init(snapshot: SnapshotBox) {
        self.snapshot = snapshot
        runner = ActionRunner(snapshot: snapshot)
    }

    func start() {
        TapThread.shared.perform { [weak self] in
            guard let self, self.tap == nil else { return }
            self.tap = TapThread.makeTap(
                types: [.scrollWheel], options: .defaultTap,
                context: Unmanaged.passUnretained(self).toOpaque(), callback: wheelRouterCallback)
            self.applyEnabled()
        }
    }

    func stop() {
        TapThread.shared.perform { [weak self] in
            guard let self else { return }
            TapThread.destroy(self.tap)
            self.tap = nil
            self.enabled = false
        }
    }

    /// Called when settings change, so the tap can be switched off whenever
    /// there is nothing for it to do.
    func refresh() {
        TapThread.shared.perform { [weak self] in self?.applyEnabled() }
    }

    private func applyEnabled() {
        guard let tap else { return }
        let wanted = snapshot.current.wheelRoutingActive
        guard wanted != enabled else { return }
        enabled = wanted
        CGEvent.tapEnable(tap: tap, enable: wanted)
        if !wanted { accumulated = 0; accumulatedFor = nil }
    }

    fileprivate func reenable() {
        guard let tap, enabled else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - Routing

    /// Returns true when the event should be swallowed.
    fileprivate func route(vertical: Double, horizontal: Double) -> Bool {
        let state = snapshot.current
        guard state.wheelRoutingActive else { return false }

        // The dominant axis decides which roll this is. The sign conventions
        // were not verified against hardware; assignments are per-direction, so
        // a mirrored setup is fixed by swapping two menu entries.
        let direction: Direction
        let magnitude: Double
        if abs(horizontal) > abs(vertical) {
            direction = horizontal > 0 ? .left : .right
            magnitude = abs(horizontal)
        } else {
            direction = vertical > 0 ? .up : .down
            magnitude = abs(vertical)
        }

        guard let action = state.wheelActions[direction] else {
            return false   // passthrough
        }

        let now = Date.timeIntervalSinceReferenceDate
        // A pause, or a change of direction, resets the run-up so separate
        // nudges don't add up.
        if now - lastEventAt > 0.3 || accumulatedFor != direction {
            accumulated = 0
            accumulatedFor = direction
        }
        lastEventAt = now
        accumulated += magnitude

        if now - lastFireAt > state.wheelCooldown, accumulated >= state.wheelThreshold {
            lastFireAt = now
            accumulated = 0
            runner.perform(action, key: state.wheelKeys[direction])
        }
        // Assigned directions are always consumed; otherwise the run-up would
        // also scroll the page.
        return true
    }
}

// Every callback below wraps its work in an autorelease pool.
//
// `CFRunLoopRun()` on a secondary thread does no autorelease pool management —
// unlike the main run loop, nothing drains the thread's top-level pool, and it
// is never popped because the call never returns. Anything autoreleased inside
// a callback therefore accumulates for the lifetime of the process. Measured at
// roughly 12KB per click before this was added: memory grew without bound and
// the pointer got progressively worse until the app was restarted.

private func wheelRouterCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    autoreleasepool {
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let router = Unmanaged<WheelRouter>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            router.reenable()
            return Unmanaged.passUnretained(event)
        }

        // Scrolls this app synthesised (gesture-mode scrolling) must never be
        // routed as if the user rolled the ball.
        if event.getIntegerValueField(.eventSourceUserData) == SyntheticMarker.value {
            return Unmanaged.passUnretained(event)
        }

        let vertical = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let horizontal = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        return router.route(vertical: vertical, horizontal: horizontal)
            ? nil : Unmanaged.passUnretained(event)
    }
}
