import CoreGraphics
import Foundation

/// Four values, one per direction, without a dictionary.
///
/// The event taps read these on every event. A `Dictionary` would mean a heap
/// allocation and reference counting in the middle of the pointer's delivery
/// path; a struct of four is copied by value with none of that.
struct Dir4<T> {
    var up: T, right: T, down: T, left: T

    init(repeating value: T) {
        up = value; right = value; down = value; left = value
    }

    subscript(direction: Direction) -> T {
        get {
            switch direction {
            case .up: return up
            case .right: return right
            case .down: return down
            case .left: return left
            }
        }
        set {
            switch direction {
            case .up: up = newValue
            case .right: right = newValue
            case .down: down = newValue
            case .left: left = newValue
            }
        }
    }
}

/// A key to replay, reduced to the two numbers needed to post it.
struct KeyStroke {
    var keyCode: CGKeyCode
    var flags: CGEventFlags

    init?(_ shortcut: Shortcut?) {
        guard let shortcut else { return nil }
        keyCode = CGKeyCode(shortcut.keyCode)
        flags = shortcut.flags
    }
}

/// What the event taps need, flattened to plain values.
///
/// `Settings` carries eight layers of dictionaries. Copying it per event —
/// which the taps used to do, under a lock — meant retaining and releasing a
/// dozen heap objects for every pointer movement, and it got heavier as more
/// layers and shortcuts were configured. This snapshot holds only what a
/// callback actually reads, and contains nothing reference-counted, so taking
/// a copy is free.
struct EventSnapshot {
    // Gesture mode
    var rotation = 1
    var gestureActions = Dir4<GestureAction>(repeating: .none)
    var gestureKeys = Dir4<KeyStroke?>(repeating: nil)
    var layerCycle: KeyStroke?

    // Gesture-mode scrolling
    var scrollVelocityMode = false
    var scrollInverted = false
    var scrollBase = 8
    var scrollStep = 5
    var scrollMax = 32
    var scrollWindow: TimeInterval = 0.4
    var velocityFloor = 40
    var velocityGain: Double = 3.0
    var velocityMax = 600

    // Scroll mode routing
    var wheelActions = Dir4<GestureAction?>(repeating: nil)
    var wheelKeys = Dir4<KeyStroke?>(repeating: nil)
    var wheelThreshold: Double = 60
    var wheelCooldown: TimeInterval = 0.6
    var wheelRoutingActive = false

    // Pointer
    var freezeEnabled = true
    var freezeThreshold: CGFloat = 8
    var freezeHold: TimeInterval = 0.12

    init() {}

    init(_ settings: Settings) {
        rotation = settings.rotation

        let layer = settings.current
        for direction in Direction.allCases {
            gestureActions[direction] = layer.action(for: direction)
            gestureKeys[direction] = KeyStroke(layer.shortcuts[direction])
            wheelActions[direction] = settings.wheelActions[direction]
            wheelKeys[direction] = KeyStroke(settings.wheelShortcuts[direction])
        }
        layerCycle = KeyStroke(settings.layerCycleShortcut)

        scrollVelocityMode = settings.scrollMode == .velocity
        scrollInverted = settings.scrollInverted
        scrollBase = settings.scrollBase
        scrollStep = settings.scrollStep
        scrollMax = settings.scrollMax
        scrollWindow = settings.scrollWindow
        velocityFloor = settings.velocityFloor
        velocityGain = settings.velocityGain
        velocityMax = settings.velocityMax

        wheelThreshold = Double(settings.wheelSpacesThreshold)
        wheelCooldown = settings.wheelSpacesCooldown
        wheelRoutingActive = !settings.wheelActions.isEmpty

        freezeEnabled = settings.clickFreezeEnabled
        freezeThreshold = CGFloat(settings.clickFreezeThreshold)
        freezeHold = settings.clickFreezeHold
    }
}

/// Holds a snapshot for the tap threads to read.
///
/// `os_unfair_lock` rather than `NSLock`: this is taken on every event, and the
/// critical section is a plain struct copy.
final class SnapshotBox: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var value: EventSnapshot

    init(_ value: EventSnapshot) { self.value = value }

    var current: EventSnapshot {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return value
        }
        set {
            os_unfair_lock_lock(&lock)
            value = newValue
            os_unfair_lock_unlock(&lock)
        }
    }
}
