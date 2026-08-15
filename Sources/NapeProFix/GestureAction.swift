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

/// Marks events this app synthesised, so its own taps can recognise and
/// ignore them. Without this, a gesture-scroll posted here would re-enter
/// WheelRouter's tap and could be swallowed as if the user had rolled the ball.
enum SyntheticMarker {
    static let value: Int64 = 0x4E50_4658  // "NPFX"
}

/// Synthesises the events for each action.
///
/// Reads a plain-value snapshot rather than `Settings`, because this runs on
/// the tap thread inside the event delivery path.
///
/// Every posted event has its flags set explicitly. Whatever modifiers happen
/// to be physically held get OR'd into synthetic events otherwise, which is
/// enough to turn a scroll into a zoom.
final class ActionRunner {
    private let snapshot: SnapshotBox
    private var lastScrollAt: TimeInterval = 0
    private var scrollStreak = 0

    init(snapshot: SnapshotBox) {
        self.snapshot = snapshot
    }

    func perform(_ action: GestureAction, key: KeyStroke? = nil) {
        switch action {
        case .shortcut:
            if let key { self.key(key.keyCode, flags: key.flags) }
        case .scrollUp:       scroll(sign: 1)
        case .scrollDown:     scroll(sign: -1)
        case .spaceLeft:      switchSpace(keyCode: 123)   // left arrow
        case .spaceRight:     switchSpace(keyCode: 124)   // right arrow
        case .missionControl: self.key(126, flags: [.maskControl, .maskSecondaryFn])
        case .appWindows:     self.key(125, flags: [.maskControl, .maskSecondaryFn])
        case .browserBack:    self.key(123, flags: [.maskCommand])
        case .browserForward: self.key(124, flags: [.maskCommand])
        case .none:           break
        }
    }

    // MARK: - Scroll

    /// A gesture is a discrete event; the ball's travel never reaches us.
    /// What does scale with rolling speed is how often the events arrive, so
    /// both modes derive their magnitude from event timing.
    private func scroll(sign: Int32) {
        let state = snapshot.current
        let now = Date.timeIntervalSinceReferenceDate
        let interval = now - lastScrollAt
        lastScrollAt = now

        let direction = state.scrollInverted ? -sign : sign
        if state.scrollVelocityMode {
            // Estimate speed from the event rate. Quadratic in the rate, so
            // slow rolls stay near the floor and fast rolls pull away — the
            // same shape as a pointer acceleration curve.
            let rate = min(1.0 / max(interval, 0.02), 30)   // events per second
            let accelerated = state.velocityGain * rate * rate
            let amount = min(max(Int(accelerated), state.velocityFloor), state.velocityMax)
            post(units: .pixel, amount: Int32(amount) * direction)
        } else {
            if interval < state.scrollWindow {
                scrollStreak += 1
            } else {
                scrollStreak = 0
            }
            let amount = min(state.scrollBase + scrollStreak * state.scrollStep, state.scrollMax)
            post(units: .line, amount: Int32(amount) * direction)
        }
    }

    private func post(units: CGScrollEventUnit, amount: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: units,
                                  wheelCount: 1,
                                  wheel1: amount,
                                  wheel2: 0,
                                  wheel3: 0) else { return }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticMarker.value)
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
