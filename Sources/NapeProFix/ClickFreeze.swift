import AppKit
import CoreGraphics

/// Pins the cursor while a mouse button is down, so a click lands where it was
/// aimed.
///
/// On a trackball the ball turns slightly as the finger presses and releases,
/// which nudges the pointer off the target — the click registers a few pixels
/// away from what was being pointed at. Holding the pointer still for the
/// duration of the press removes that.
///
/// Three things about the implementation matter, all learned by getting them
/// wrong first:
///
/// 1. **The pointer is held by swallowing movement events**, not by detaching
///    the cursor with `CGAssociateMouseAndMouseCursorPosition(0)`. While the
///    cursor is detached the system keeps moving its own internal position, and
///    re-associating snaps the cursor to wherever that drifted to — the pointer
///    visibly warps.
///
/// 2. **Movement is only routed through this process while a button is down.**
///    The motion tap stays disabled the rest of the time, so ordinary pointer
///    movement never enters the app at all.
///
/// 3. **Everything runs on `TapThread`**, never the main thread.
final class ClickFreeze: @unchecked Sendable {
    private let snapshot: SnapshotBox

    /// Cheap and always on: just watches for button presses.
    private var buttonTap: CFMachPort?
    /// Only enabled while frozen, because it is in the path of every movement.
    private var motionTap: CFMachPort?

    // Touched only on the tap thread.
    private var isFrozen = false
    private var travel: CGFloat = 0
    private var releaseTimer: Timer?
    private var safetyTimer: Timer?

    init(snapshot: SnapshotBox) {
        self.snapshot = snapshot
    }

    func start() {
        TapThread.shared.perform { [weak self] in
            guard let self, self.buttonTap == nil else { return }
            self.buttonTap = TapThread.makeTap(
                types: [.leftMouseDown, .leftMouseUp,
                        .rightMouseDown, .rightMouseUp,
                        .otherMouseDown, .otherMouseUp],
                options: .listenOnly, context: Unmanaged.passUnretained(self).toOpaque(), callback: buttonTapCallback)
            if let tap = self.buttonTap { CGEvent.tapEnable(tap: tap, enable: true) }

            self.motionTap = TapThread.makeTap(
                types: [.mouseMoved, .leftMouseDragged,
                        .rightMouseDragged, .otherMouseDragged],
                options: .defaultTap, context: Unmanaged.passUnretained(self).toOpaque(), callback: motionTapCallback)
            // Off until a button goes down.
            if let tap = self.motionTap { CGEvent.tapEnable(tap: tap, enable: false) }
        }
    }

    func stop() {
        TapThread.shared.perform { [weak self] in
            guard let self else { return }
            self.thaw()
            TapThread.destroy(self.buttonTap)
            TapThread.destroy(self.motionTap)
            self.buttonTap = nil
            self.motionTap = nil
        }
    }

    fileprivate func reenable(_ tap: CFMachPort?) {
        guard let tap else { return }
        // The motion tap must not come back enabled if nothing is frozen —
        // that would put every pointer movement back in our path for good.
        if tap === motionTap && !isFrozen { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    fileprivate var buttons: CFMachPort? { buttonTap }
    fileprivate var motion: CFMachPort? { motionTap }

    // MARK: - Handling

    fileprivate func handleButton(type: CGEventType) {
        let state = snapshot.current
        guard state.freezeEnabled else {
            if isFrozen { thaw() }
            return
        }
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            freeze()
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard isFrozen else { return }
            // Hold a moment longer: the ball usually turns as the finger lifts,
            // which is exactly the drift being corrected.
            releaseTimer?.invalidate()
            releaseTimer = scheduled(after: state.freezeHold) { [weak self] in
                self?.thaw()
            }
        default:
            break
        }
    }

    /// Returns true when the movement should be swallowed.
    fileprivate func shouldSwallowMotion(dx: CGFloat, dy: CGFloat) -> Bool {
        guard isFrozen else { return false }
        travel += (dx * dx + dy * dy).squareRoot()
        // Deliberate movement: hand the pointer back and stay out of the way.
        if travel > snapshot.current.freezeThreshold {
            thaw()
            return false
        }
        return true
    }

    private func freeze() {
        guard !isFrozen else { return }
        releaseTimer?.invalidate()
        travel = 0
        isFrozen = true
        if let motionTap { CGEvent.tapEnable(tap: motionTap, enable: true) }

        safetyTimer?.invalidate()
        safetyTimer = scheduled(after: 3) { [weak self] in self?.thaw() }
    }

    private func thaw() {
        releaseTimer?.invalidate(); releaseTimer = nil
        safetyTimer?.invalidate(); safetyTimer = nil
        isFrozen = false
        travel = 0
        if let motionTap { CGEvent.tapEnable(tap: motionTap, enable: false) }
    }

    /// Timers must run in `.common` modes. Registered in the default mode only,
    /// they stop firing while the run loop is tracking, and the release would
    /// never run — leaving the pointer pinned.
    private func scheduled(after seconds: TimeInterval,
                           _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            autoreleasepool { body() }
        }
        RunLoop.current.add(timer, forMode: .common)
        return timer
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

private func buttonTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    autoreleasepool {
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let freeze = Unmanaged<ClickFreeze>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            freeze.reenable(freeze.buttons)
            return Unmanaged.passUnretained(event)
        }
        freeze.handleButton(type: type)
        return Unmanaged.passUnretained(event)
    }
}

private func motionTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    autoreleasepool {
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let freeze = Unmanaged<ClickFreeze>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            freeze.reenable(freeze.motion)
            return Unmanaged.passUnretained(event)
        }

        let dx = CGFloat(event.getDoubleValueField(.mouseEventDeltaX))
        let dy = CGFloat(event.getDoubleValueField(.mouseEventDeltaY))
        return freeze.shouldSwallowMotion(dx: dx, dy: dy) ? nil : Unmanaged.passUnretained(event)
    }
}
