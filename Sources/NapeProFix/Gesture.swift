import CoreGraphics
import Foundation

/// Clockwise. Rotation correction is index arithmetic on this order, so the
/// raw values must stay in this sequence; use `menuOrder` for display.
enum Direction: Int, CaseIterable, Codable {
    case up = 0, right, down, left

    /// How directions are listed in the UI. Reading order, not geometry.
    static let menuOrder: [Direction] = [.up, .down, .left, .right]

    var label: String {
        switch self {
        case .up: return "上"
        case .right: return "右"
        case .down: return "下"
        case .left: return "左"
        }
    }

    func rotated(by steps: Int) -> Direction {
        let count = Direction.allCases.count
        return Direction(rawValue: ((rawValue + steps) % count + count) % count)!
    }
}

/// The keys the Keychron Launcher is configured to send for each gesture.
///
/// Modifiers must not be used. The firmware presses and releases the modifier
/// in full on every single gesture, so rolling continuously reads as the
/// modifier being tapped over and over. That cannot be filtered out here:
/// flagsChanged arrives before the character key, so there is no way to tell a
/// gesture apart from ordinary typing at the moment it arrives, and the device
/// reports the same keyboard type as the built-in keyboard.
///
/// These four keys are absent from Mac keyboards and do nothing on their own,
/// which is what makes them safe to use bare.
///
/// Two Launcher entries look usable but are not:
///   Pause       - macOS has no key code for it; the event vanishes entirely.
///   Scroll Lock - arrives as F14, which macOS consumes as brightness-down
///                 below the event tap. No userspace app can take it.
enum GestureKey: CGKeyCode, CaseIterable {
    case printScreen = 105  // f13
    case keypadSlash = 75   // Launcher: テンキーの ÷
    case numLock     = 71   // padclear
    case insert      = 114  // help

    /// The direction the firmware believes the ball moved.
    var firmwareDirection: Direction {
        switch self {
        case .printScreen: return .up
        case .keypadSlash: return .down
        case .numLock:     return .left
        case .insert:      return .right
        }
    }

    var launcherLabel: String {
        switch self {
        case .printScreen: return "Print Screen"
        case .keypadSlash: return "÷ (テンキー)"
        case .numLock:     return "Num Lock"
        case .insert:      return "Insert"
        }
    }

    static func from(keyCode: CGKeyCode) -> GestureKey? {
        GestureKey(rawValue: keyCode)
    }
}
