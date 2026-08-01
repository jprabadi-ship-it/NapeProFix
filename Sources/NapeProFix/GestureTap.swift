import CoreGraphics
import Foundation

/// Watches for the four gesture keys and swallows them.
///
/// The keys are consumed rather than passed through: they are meant to be
/// opaque carriers for "the ball moved this way", so nothing downstream should
/// ever see them.
final class GestureTap: @unchecked Sendable {
    /// Called with the direction the firmware reported, not the physical one.
    var onGesture: ((Direction) -> Void)?
    /// Any other key press. Return true to swallow it, as the layer switch
    /// shortcut needs to, so it does not also reach the frontmost app.
    var onKey: ((CGKeyCode, CGEventFlags) -> Bool)?
    var onTapDisabled: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Keys whose press was handled, so their release can be swallowed too.
    private var swallowedKeys: Set<CGKeyCode> = []

    var isRunning: Bool { eventTap != nil }

    @discardableResult
    func start() -> Bool {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return true
        }

        let types: [CGEventType] = [.keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: gestureTapCallback,
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

    /// The system disables a tap that takes too long. Re-enable rather than
    /// silently dying.
    fileprivate func reenable() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        onTapDisabled?()
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if let gestureKey = GestureKey.from(keyCode: keyCode) {
            if type == .keyDown {
                onGesture?(gestureKey.firmwareDirection)
            }
            return nil  // swallow both down and up
        }

        // Act on the press only. Firing on key up as well ran the handler
        // twice per press, which cancelled itself out whenever the action was
        // a toggle — the layer switch went forward and straight back.
        // The release still has to be swallowed so the key never reaches the
        // app underneath.
        switch type {
        case .keyDown:
            if onKey?(keyCode, event.flags) == true {
                swallowedKeys.insert(keyCode)
                return nil
            }
        case .keyUp:
            if swallowedKeys.remove(keyCode) != nil {
                return nil
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

private func gestureTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<GestureTap>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reenable()
        return Unmanaged.passUnretained(event)
    }
    return tap.handle(type: type, event: event)
}
