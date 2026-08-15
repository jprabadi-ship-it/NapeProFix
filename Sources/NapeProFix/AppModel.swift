import AppKit
import Combine

/// Shared state for the menu bar item and the settings window, so both see the
/// same settings and either can change them.
@MainActor
final class AppModel: ObservableObject {
    @Published var settings: Settings {
        didSet { publish() }
    }

    /// The taps read this, never `settings`. Rebuilt on change, on the main
    /// thread, so the event path only ever copies plain values.
    private let snapshot = SnapshotBox(EventSnapshot())

    private func publish() {
        SettingsStore.save(settings)
        snapshot.current = EventSnapshot(settings)
        wheelRouter.refresh()
    }

    /// Whether the event tap is running, i.e. whether accessibility has been
    /// granted. Surfaced so the settings window can say so plainly.
    @Published private(set) var isActive = false

    /// Master off switch. Detaches every tap, so the app is provably out of the
    /// input path — the fastest way to tell whether a pointer problem is this
    /// app or something else on the machine. Deliberately not persisted: a
    /// paused app that stayed paused across a restart would look broken.
    @Published private(set) var isPaused = false

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            tap.stop()
            clickFreeze.stop()
            wheelRouter.stop()
        } else {
            _ = tap.start()
            clickFreeze.start()
            wheelRouter.start()
        }
    }

    private lazy var tap = GestureTap(snapshot: snapshot)
    private lazy var clickFreeze = ClickFreeze(snapshot: snapshot)
    private lazy var wheelRouter = WheelRouter(snapshot: snapshot)
    private var permissionTimer: Timer?

    init() {
        settings = SettingsStore.load()
        snapshot.current = EventSnapshot(settings)

        // Fired on the tap thread. Only the state change comes back to the
        // main actor; nothing in the event path waits for it.
        tap.onLayerCycle = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.settings.activeLayer =
                    self.settings.nextConfiguredLayer(after: self.settings.activeLayer)
            }
        }
    }

    // MARK: - Permission

    func start() {
        TapThread.shared.start()
        if tap.start() {
            isActive = true
            clickFreeze.start()
            wheelRouter.start()
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
        clickFreeze.stop()
        wheelRouter.stop()
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
        settings.scrollInverted = defaults.scrollInverted
        settings.velocityFloor = defaults.velocityFloor
        settings.velocityGain = defaults.velocityGain
        settings.velocityMax = defaults.velocityMax
    }

    // MARK: - Scroll-mode routing

    /// nil means passthrough — the direction keeps its native smooth scrolling.
    func assignWheel(_ action: GestureAction?, to direction: Direction) {
        if let action {
            settings.wheelActions[direction] = action
        } else {
            settings.wheelActions[direction] = nil
            settings.wheelShortcuts[direction] = nil
        }
    }

    func recordWheelShortcut(for direction: Direction) {
        guard let shortcut = ShortcutRecorder.record(
            title: "スクロールモードの\(direction.label)方向") else { return }
        settings.wheelShortcuts[direction] = shortcut
        settings.wheelActions[direction] = .shortcut
    }

    func clearWheelShortcut(for direction: Direction) {
        settings.wheelShortcuts[direction] = nil
        if settings.wheelActions[direction] == .shortcut {
            settings.wheelActions[direction] = nil
        }
    }

    func resetWheelSettings() {
        let defaults = Settings()
        settings.wheelActions = [:]
        settings.wheelShortcuts = [:]
        settings.wheelSpacesThreshold = defaults.wheelSpacesThreshold
        settings.wheelSpacesCooldown = defaults.wheelSpacesCooldown
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
