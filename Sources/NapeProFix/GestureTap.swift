import CoreGraphics
import Foundation

/// Watches for the four gesture keys and swallows them.
///
/// The keys are consumed rather than passed through: they are meant to be
/// opaque carriers for "the ball moved this way", so nothing downstream should
/// ever see them.
///
/// Everything decided here is decided on the tap thread from a plain-value
/// snapshot. It used to hop to the main actor for each event, which put every
/// keystroke in the system behind whatever the UI happened to be doing.
final class GestureTap: @unchecked Sendable {
    private let snapshot: SnapshotBox
    private let runner: ActionRunner
    /// Called on the tap thread when the layer-cycle key fires.
    var onLayerCycle: (() -> Void)?

    private var tap: CFMachPort?
    private var swallowedKeys: Set<CGKeyCode> = []
    private var running = false

    init(snapshot: SnapshotBox) {
        self.snapshot = snapshot
        runner = ActionRunner(snapshot: snapshot)
    }

    var isRunning: Bool { running }

    /// Creating the tap is the only way to find out whether accessibility has
    /// been granted, so this reports back synchronously.
    @discardableResult
    func start() -> Bool {
        if running { return true }
        let semaphore = DispatchSemaphore(value: 0)
        let created = Flag()

        TapThread.shared.perform { [weak self] in
            guard let self else { semaphore.signal(); return }
            if let tap = TapThread.makeTap(
                types: [.keyDown, .keyUp], options: .defaultTap,
                context: Unmanaged.passUnretained(self).toOpaque(),
                callback: gestureTapCallback) {
                self.tap = tap
                CGEvent.tapEnable(tap: tap, enable: true)
                created.value = true
            }
            semaphore.signal()
        }
        semaphore.wait()
        running = created.value
        return running
    }

    func stop() {
        TapThread.shared.perform { [weak self] in
            guard let self else { return }
            TapThread.destroy(self.tap)
            self.tap = nil
        }
        running = false
    }

    fileprivate func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns true when the event should be swallowed.
    fileprivate func handle(type: CGEventType, keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        if let gestureKey = GestureKey.from(keyCode: keyCode) {
            if type == .keyDown {
                let state = snapshot.current
                let resolved = gestureKey.firmwareDirection.rotated(by: state.rotation)
                runner.perform(state.gestureActions[resolved],
                               key: state.gestureKeys[resolved])
            }
            return true   // swallow both down and up
        }

        // Act on the press only. Firing on key up as well ran the handler twice
        // per press, which cancelled itself out for a toggle — the layer switch
        // went forward and straight back. The release still has to be swallowed
        // so the key never reaches the app underneath.
        switch type {
        case .keyDown:
            guard let cycle = snapshot.current.layerCycle, cycle.keyCode == keyCode else {
                return false
            }
            // Compare only the modifiers that get recorded; the event carries
            // extra bits, such as the numeric-keypad flag, that would never match.
            let mask: CGEventFlags = [
                .maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn,
            ]
            guard flags.intersection(mask) == cycle.flags.intersection(mask) else { return false }
            swallowedKeys.insert(keyCode)
            onLayerCycle?()
            return true

        case .keyUp:
            return swallowedKeys.remove(keyCode) != nil

        default:
            return false
        }
    }
}

/// Carries the result out of the tap thread; a captured `var` cannot be
/// mutated from a `@Sendable` closure.
private final class Flag: @unchecked Sendable {
    var value = false
}

// Every callback below wraps its work in an autorelease pool.
//
// `CFRunLoopRun()` on a secondary thread does no autorelease pool management —
// unlike the main run loop, nothing drains the thread's top-level pool, and it
// is never popped because the call never returns. Anything autoreleased inside
// a callback therefore accumulates for the lifetime of the process. Measured at
// roughly 12KB per click before this was added: memory grew without bound and
// the pointer got progressively worse until the app was restarted.

private func gestureTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    autoreleasepool {
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let tap = Unmanaged<GestureTap>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            tap.reenable()
            return Unmanaged.passUnretained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        return tap.handle(type: type, keyCode: keyCode, flags: event.flags)
            ? nil : Unmanaged.passUnretained(event)
    }
}
