import AppKit
import Combine

/// Shared state for the menu bar item and the settings window, so both see the
/// same settings and either can change them.
@MainActor
final class AppModel: ObservableObject {
    @Published var settings: Settings {
        didSet {
            SettingsStore.save(settings)
            runner.update(settings: settings)
            clickFreeze.settings = settings
        }
    }

    /// Whether the event tap is running, i.e. whether accessibility has been
    /// granted. Surfaced so the settings window can say so plainly.
    @Published private(set) var isActive = false

    private let tap = GestureTap()
    private lazy var runner = ActionRunner(settings: settings)
    private lazy var clickFreeze = ClickFreeze(settings: settings)
    private var permissionTimer: Timer?

    init() {
        settings = SettingsStore.load()

        tap.onGesture = { [weak self] firmwareDirection in
            MainActor.assumeIsolated { self?.handle(firmwareDirection) }
        }
        tap.onKey = { [weak self] keyCode, flags in
            MainActor.assumeIsolated {
                self?.handleLayerSwitch(keyCode: keyCode, flags: flags) ?? false
            }
        }
    }

    // MARK: - Gestures

    private func handle(_ firmwareDirection: Direction) {
        let resolved = firmwareDirection.rotated(by: settings.rotation)
        let layer = settings.current
        runner.perform(layer.action(for: resolved), shortcut: layer.shortcuts[resolved])
    }

    /// Returns true when the key was the layer switch and should be swallowed.
    private func handleLayerSwitch(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let shortcut = settings.layerCycleShortcut,
              CGKeyCode(shortcut.keyCode) == keyCode
        else { return false }

        // Compare only the modifiers we record; the event carries extra bits
        // such as the numeric-keypad flag that would never match otherwise.
        let mask: CGEventFlags = [
            .maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn,
        ]
        guard flags.intersection(mask) == shortcut.flags.intersection(mask) else { return false }

        settings.activeLayer = settings.nextConfiguredLayer(after: settings.activeLayer)
        return true
    }

    // MARK: - Permission

    func start() {
        if tap.start() {
            isActive = true
            clickFreeze.start()
            permissionTimer?.invalidate()
            permissionTimer = nil
            return
        }
        isActive = false
        // tapCreate only fails for want of accessibility permission. Granting
        // it does not notify us, so poll until it lands rather than making the
        // user restart the app.
        promptForAccessibility()
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                self.start()
            }
        }
    }

    func promptForAccessibility() {
        // The constant itself is a global var and so not concurrency-safe to
        // reference; its value is stable, so use the string directly.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        promptForAccessibility()
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        tap.stop()
        // Must run: the cursor is detached from the mouse while frozen.
        clickFreeze.stop()
    }

    // MARK: - Edits

    func rotate() {
        settings.rotation = (settings.rotation + 1) % Direction.allCases.count
    }

    func setRotation(_ value: Int) {
        settings.rotation = value
    }

    func assign(_ action: GestureAction, to direction: Direction, layer: Int) {
        settings.update(layer: layer) { $0.actions[direction] = action }
    }

    func recordShortcut(for direction: Direction, layer: Int) {
        guard let shortcut = ShortcutRecorder.record(
            title: "レイヤー \(layer) の\(direction.label)方向") else { return }
        settings.update(layer: layer) {
            $0.shortcuts[direction] = shortcut
            $0.actions[direction] = .shortcut
        }
    }

    func clearShortcut(for direction: Direction, layer: Int) {
        settings.update(layer: layer) {
            $0.shortcuts[direction] = nil
            if $0.action(for: direction) == .shortcut { $0.actions[direction] = .none }
        }
    }

    /// Scroll tuning is easy to get lost in; this is the way back.
    func resetScrollSettings() {
        let defaults = Settings()
        settings.scrollBase = defaults.scrollBase
        settings.scrollStep = defaults.scrollStep
        settings.scrollMax = defaults.scrollMax
        settings.scrollWindow = defaults.scrollWindow
    }

    func resetPointerSettings() {
        let defaults = Settings()
        settings.clickFreezeEnabled = defaults.clickFreezeEnabled
        settings.clickFreezeThreshold = defaults.clickFreezeThreshold
        settings.clickFreezeHold = defaults.clickFreezeHold
    }

    func recordLayerCycleShortcut() {
        guard let shortcut = ShortcutRecorder.record(title: "レイヤー切替") else { return }
        settings.layerCycleShortcut = shortcut
    }

    func clearLayerCycleShortcut() {
        settings.layerCycleShortcut = nil
    }
}
