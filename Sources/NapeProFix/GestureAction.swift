import CoreGraphics
import Foundation

enum GestureAction: String, CaseIterable, Codable {
    case scrollUp
    case scrollDown
    case spaceLeft
    case spaceRight
    case missionControl
    case appWindows
    case browserBack
    case browserForward
    /// Replays whatever shortcut is recorded for that direction.
    case shortcut
    case none

    var label: String {
        switch self {
        case .scrollUp:       return "スクロール（上）"
        case .scrollDown:     return "スクロール（下）"
        case .spaceLeft:      return "デスクトップを左へ"
        case .spaceRight:     return "デスクトップを右へ"
        case .missionControl: return "Mission Control"
        case .appWindows:     return "アプリケーションウインドウ"
        case .browserBack:    return "戻る"
        case .browserForward: return "進む"
        case .shortcut:       return "ショートカット"
        case .none:           return "なし"
        }
    }
}

/// Synthesises the events for each action.
///
/// Every posted event has its flags set explicitly. Whatever modifiers happen
/// to be physically held get OR'd into synthetic events otherwise, which is
/// enough to turn a scroll into a zoom.
final class ActionRunner {
    private var settings: Settings
    private var lastScrollAt: TimeInterval = 0
    private var scrollStreak = 0

    init(settings: Settings) {
        self.settings = settings
    }

    func update(settings: Settings) {
        self.settings = settings
    }

    func perform(_ action: GestureAction, shortcut: Shortcut? = nil) {
        switch action {
        case .shortcut:
            if let shortcut { key(CGKeyCode(shortcut.keyCode), flags: shortcut.flags) }
        case .scrollUp:       scroll(sign: 1)
        case .scrollDown:     scroll(sign: -1)
        case .spaceLeft:      switchSpace(keyCode: 123)   // left arrow
        case .spaceRight:     switchSpace(keyCode: 124)   // right arrow
        case .missionControl: key(126, flags: [.maskControl, .maskSecondaryFn])  // ctrl+up
        case .appWindows:     key(125, flags: [.maskControl, .maskSecondaryFn])  // ctrl+down
        case .browserBack:    key(123, flags: [.maskCommand])
        case .browserForward: key(124, flags: [.maskCommand])
        case .none:           break
        }
    }

    // MARK: - Scroll

    /// A gesture is a discrete event, so the only way to build speed is to let
    /// repeated gestures within a short window scroll further each time.
    private func scroll(sign: Int32) {
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastScrollAt < settings.scrollWindow {
            scrollStreak += 1
        } else {
            scrollStreak = 0
        }
        lastScrollAt = now

        let amount = min(settings.scrollBase + scrollStreak * settings.scrollStep,
                         settings.scrollMax)
        let direction = settings.scrollInverted ? -sign : sign
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .line,
                                  wheelCount: 1,
                                  wheel1: Int32(amount) * direction,
                                  wheel2: 0,
                                  wheel3: 0) else { return }
        event.flags = []
        event.post(tap: .cgSessionEventTap)
    }

    // MARK: - Keys

    /// Space switching needs the fn bit. The shortcut macOS has registered for
    /// it carries Control + Function, because arrow keys count as function
    /// keys; sending plain Control silently fails to match and is ignored.
    private func switchSpace(keyCode: CGKeyCode) {
        key(keyCode, flags: [.maskControl, .maskSecondaryFn])
    }

    private func key(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }
}
