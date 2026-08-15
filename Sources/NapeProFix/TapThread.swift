import CoreGraphics
import Foundation

/// A thread with a run loop, dedicated to event taps.
///
/// An event tap sits in the delivery path of every event it asks for: the
/// window server hands the event over and waits for the callback to return
/// before it continues. Anything that blocks the thread the tap runs on
/// therefore delays input system-wide. On the main thread, any UI work — a
/// SwiftUI update, a menu being rebuilt, a slow first draw — is enough to make
/// the pointer stutter, and it gets worse the more the app has going on.
///
/// So every tap in this app runs here instead, and nothing else does.
final class TapThread: @unchecked Sendable {
    static let shared = TapThread()

    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    private init() {}

    func start() {
        guard thread == nil else { return }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "NapeProFix.EventTaps"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()
    }

    private func run() {
        runLoop = CFRunLoopGetCurrent()
        // A run loop with no sources returns immediately, and taps are added
        // later, so hold it open with a port that never fires.
        let port = Port()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), port.source, .commonModes)
        ready.signal()
        CFRunLoopRun()
    }

    /// Runs `body` on the tap thread. Tap creation, enabling and invalidation
    /// all have to happen there so the run loop source belongs to it.
    func perform(_ body: @escaping @Sendable () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            autoreleasepool { body() }
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Creates a tap and attaches it to this thread. Call from `perform`.
    static func makeTap(
        types: [CGEventType],
        options: CGEventTapOptions,
        context: UnsafeMutableRawPointer,
        callback: @escaping CGEventTapCallBack
    ) -> CFMachPort? {
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: context
        ) else { return nil }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        return tap
    }

    static func destroy(_ tap: CFMachPort?) {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
    }

    /// A run loop source that exists only to keep the loop from exiting.
    private final class Port {
        let source: CFRunLoopSource
        init() {
            var context = CFRunLoopSourceContext()
            context.perform = { _ in }
            source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
        }
    }
}
