import AppKit
import CoreGraphics

/// Pins the cursor while a mouse button is down, so a click lands where it was
/// aimed.
///
/// On a trackball the ball turns slightly as the finger presses and releases,
/// which nudges the pointer off the target — the click registers a few pixels
/// away from what was being pointed at. Freezing the cursor for the duration of
/// the press, and putting it back where the press started, removes that.
///
/// Dragging still has to work, so the freeze lifts as soon as the movement
/// during the press passes a threshold: past that, the motion is deliberate.
@MainActor
final class ClickFreeze {
    var settings: Settings

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var frozenAt: CGPoint?
    private var travel: CGFloat = 0
    private var releaseTimer: Timer?
    /// Last resort. If anything goes wrong while the cursor is detached from
    /// the mouse, the pointer would be stuck for good.
    private var safetyTimer: Timer?

    init(settings: Settings) {
        self.settings = settings
    }

    @discardableResult
    func start() -> Bool {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return true
        }

        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,   // never swallow mouse events
            eventsOfInterest: mask,
            callback: clickFreezeCallback,
            userInfo: context
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        thaw(restore: false)
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
    }

    fileprivate func reenable() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    // MARK: - Handling

    /// Takes the movement as plain numbers rather than the event itself, so
    /// nothing crosses the actor boundary that the compiler cannot reason about.
    fileprivate func handle(type: CGEventType, dx: CGFloat, dy: CGFloat) {
        guard settings.clickFreezeEnabled else { return }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            freeze()

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard frozenAt != nil else { return }
            travel += (dx * dx + dy * dy).squareRoot()
            // Deliberate movement: hand the pointer back and stay out of the way.
            if travel > CGFloat(settings.clickFreezeThreshold) {
                thaw(restore: false)
            }

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard frozenAt != nil else { return }
            // Hold a moment longer: the ball usually turns as the finger lifts,
            // which is exactly the drift being corrected.
            releaseTimer?.invalidate()
            releaseTimer = Timer.scheduledTimer(
                withTimeInterval: settings.clickFreezeHold, repeats: false) { _ in
                    MainActor.assumeIsolated { self.thaw(restore: true) }
                }

        default:
            break
        }
    }

    private func freeze() {
        guard frozenAt == nil else { return }
        releaseTimer?.invalidate()
        travel = 0
        frozenAt = currentLocation()
        CGAssociateMouseAndMouseCursorPosition(0)

        safetyTimer?.invalidate()
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            MainActor.assumeIsolated { self.thaw(restore: false) }
        }
    }

    private func thaw(restore: Bool) {
        releaseTimer?.invalidate(); releaseTimer = nil
        safetyTimer?.invalidate(); safetyTimer = nil
        guard let point = frozenAt else { return }
        frozenAt = nil
        travel = 0
        if restore { CGWarpMouseCursorPosition(point) }
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Global (top-left origin) location, matching the space CGWarp uses.
    private func currentLocation() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        guard let primary = NSScreen.screens.first else { return mouse }
        return CGPoint(x: mouse.x, y: primary.frame.maxY - mouse.y)
    }
}

private func clickFreezeCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let freeze = Unmanaged<ClickFreeze>.fromOpaque(userInfo).takeUnretainedValue()

    let dx = CGFloat(event.getDoubleValueField(.mouseEventDeltaX))
    let dy = CGFloat(event.getDoubleValueField(.mouseEventDeltaY))

    MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            freeze.reenable()
        } else {
            freeze.handle(type: type, dx: dx, dy: dy)
        }
    }
    return Unmanaged.passUnretained(event)
}
