import AppKit
import ServiceManagement

@main
enum NapeProFixApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // menu bar only
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let tap = GestureTap()
    private var settings = SettingsStore.load()
    private lazy var runner = ActionRunner(settings: settings)
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.image?.accessibilityDescription = "NapeProFix"

        // The tap callback is delivered on the main run loop, so this is
        // already the main actor; the compiler just cannot see that through
        // the C callback.
        tap.onGesture = { [weak self] firmwareDirection in
            MainActor.assumeIsolated {
                self?.handle(firmwareDirection)
            }
        }
        tap.onKey = { [weak self] keyCode, flags in
            MainActor.assumeIsolated {
                self?.handleLayerSwitch(keyCode: keyCode, flags: flags) ?? false
            }
        }

        startTap()
        rebuildMenu()
        showSetupOnFirstLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
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
        SettingsStore.save(settings)
        rebuildMenu()
        return true
    }

    private func startTap() {
        if tap.start() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            return
        }
        // tapCreate only fails for want of accessibility permission. Granting
        // it does not notify us, so poll until it lands rather than making the
        // user restart the app.
        promptForAccessibility()
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                if self.tap.start() {
                    self.permissionTimer?.invalidate()
                    self.permissionTimer = nil
                    self.rebuildMenu()
                }
            }
        }
    }

    private func promptForAccessibility() {
        // The constant itself is a global var and so not concurrency-safe to
        // reference; its value is stable, so use the string directly.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let status = tap.isRunning ? "動作中" : "アクセシビリティ権限が必要"
        let header = NSMenuItem(title: "NapeProFix — \(status)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !tap.isRunning {
            menu.addItem(item("権限を許可…", #selector(openAccessibilitySettings)))
        }

        menu.addItem(.separator())

        let rotationHeader = NSMenuItem(
            title: "回転補正: \(settings.rotation * 90)°", action: nil, keyEquivalent: "")
        rotationHeader.isEnabled = false
        menu.addItem(rotationHeader)
        menu.addItem(item("90°回す", #selector(rotate)))
        menu.addItem(item("0°に戻す", #selector(resetRotation)))

        menu.addItem(.separator())

        // Assignments are shown per physical direction, which is what the user
        // actually experiences; the rotation is already applied by then.
        for index in 0..<Settings.layerCount {
            let config = settings.layer(index)
            let active = (index == settings.activeLayer)
            let summary = config.isEmpty ? "未設定" : Direction.menuOrder
                .map { config.label(for: $0) }
                .joined(separator: " / ")

            let parent = NSMenuItem(
                title: "レイヤー \(index)\(active ? "（使用中）" : "") — \(summary)",
                action: nil, keyEquivalent: "")
            parent.state = active ? .on : .off
            parent.submenu = layerMenu(index)
            menu.addItem(parent)
        }

        menu.addItem(.separator())

        let cycleTitle = settings.layerCycleShortcut
            .map { "レイヤー切替: \($0.display)" } ?? "レイヤー切替ショートカットを記録…"
        menu.addItem(item(cycleTitle, #selector(recordLayerCycleShortcut)))
        if settings.layerCycleShortcut != nil {
            menu.addItem(item("レイヤー切替ショートカットを削除", #selector(clearLayerCycleShortcut)))
        }

        menu.addItem(.separator())

        let login = item("ログイン時に起動", #selector(toggleLoginItem))
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(item("動かないとき / Launcher の設定…", #selector(showLauncherSetup)))
        menu.addItem(.separator())
        menu.addItem(item("終了", #selector(quit)))

        statusItem.menu = menu
    }

    /// レイヤー N → 上/下/左/右 → 動作、の三段構成。
    private func layerMenu(_ index: Int) -> NSMenu {
        let config = settings.layer(index)
        let menu = NSMenu()

        let use = NSMenuItem(
            title: "このレイヤーを使う", action: #selector(selectLayer(_:)), keyEquivalent: "")
        use.target = self
        use.state = (index == settings.activeLayer) ? .on : .off
        use.representedObject = index
        menu.addItem(use)
        menu.addItem(.separator())

        for direction in Direction.menuOrder {
            let current = config.action(for: direction)
            let parent = NSMenuItem(
                title: "\(direction.label): \(config.label(for: direction))",
                action: nil, keyEquivalent: "")
            let submenu = NSMenu()

            // The shortcut case is driven by its own recorder entry below.
            for action in GestureAction.allCases where action != .shortcut {
                let entry = NSMenuItem(
                    title: action.label, action: #selector(assign(_:)), keyEquivalent: "")
                entry.target = self
                entry.state = (action == current) ? .on : .off
                entry.representedObject = [index, direction.rawValue, action.rawValue] as [Any]
                submenu.addItem(entry)
            }

            submenu.addItem(.separator())

            let recorded = config.shortcuts[direction]
            let title = recorded.map { "ショートカット: \($0.display)" } ?? "ショートカットを記録…"
            let record = NSMenuItem(
                title: title, action: #selector(recordShortcut(_:)), keyEquivalent: "")
            record.target = self
            record.state = (current == .shortcut) ? .on : .off
            record.representedObject = [index, direction.rawValue] as [Any]
            submenu.addItem(record)

            if recorded != nil {
                let clear = NSMenuItem(
                    title: "ショートカットを削除", action: #selector(clearShortcut(_:)),
                    keyEquivalent: "")
                clear.target = self
                clear.representedObject = [index, direction.rawValue] as [Any]
                submenu.addItem(clear)
            }

            parent.submenu = submenu
            menu.addItem(parent)
        }

        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    private func persist() {
        SettingsStore.save(settings)
        runner.update(settings: settings)
        rebuildMenu()
        reopenMenu()
    }

    /// AppKit always dismisses the menu once an item is chosen, and offers no
    /// way to opt out. Clicking the status item again is the only way to keep
    /// the menu up for another change; it has to wait for the current menu to
    /// finish closing or the click is swallowed.
    private func reopenMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    // MARK: - Actions

    @objc private func rotate() {
        settings.rotation = (settings.rotation + 1) % Direction.allCases.count
        persist()
    }

    @objc private func resetRotation() {
        settings.rotation = 0
        persist()
    }

    @objc private func selectLayer(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        settings.activeLayer = index
        persist()
    }

    @objc private func assign(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [Any], parts.count == 3,
              let layer = parts[0] as? Int,
              let rawDirection = parts[1] as? Int,
              let rawAction = parts[2] as? String,
              let direction = Direction(rawValue: rawDirection),
              let action = GestureAction(rawValue: rawAction)
        else { return }
        settings.update(layer: layer) { $0.actions[direction] = action }
        persist()
    }

    @objc private func recordLayerCycleShortcut() {
        guard let shortcut = ShortcutRecorder.record(title: "レイヤー切替") else { return }
        settings.layerCycleShortcut = shortcut
        persist()
    }

    @objc private func clearLayerCycleShortcut() {
        settings.layerCycleShortcut = nil
        persist()
    }

    @objc private func recordShortcut(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [Any], parts.count == 2,
              let layer = parts[0] as? Int,
              let raw = parts[1] as? Int,
              let direction = Direction(rawValue: raw)
        else { return }

        guard let shortcut = ShortcutRecorder.record(
            title: "レイヤー \(layer) の\(direction.label)方向") else { return }
        settings.update(layer: layer) {
            $0.shortcuts[direction] = shortcut
            $0.actions[direction] = .shortcut
        }
        persist()
    }

    @objc private func clearShortcut(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [Any], parts.count == 2,
              let layer = parts[0] as? Int,
              let raw = parts[1] as? Int,
              let direction = Direction(rawValue: raw)
        else { return }
        settings.update(layer: layer) {
            $0.shortcuts[direction] = nil
            if $0.action(for: direction) == .shortcut { $0.actions[direction] = .none }
        }
        persist()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("login item toggle failed: \(error)")
        }
        rebuildMenu()
        reopenMenu()
    }

    @objc private func openAccessibilitySettings() {
        promptForAccessibility()
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showLauncherSetup() {
        let rows = GestureKey.allCases
            .map { "　\($0.firmwareDirection.label)　→　\($0.launcherLabel)" }
            .joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = "Keychron Launcher 側の設定"
        alert.informativeText = """
        この2つが揃っていないとジェスチャは動きません。

        ■ アドバンスモード
        「常にジェスチャーモードを有効にする」をオンにしてください。
        オフの場合、ジェスチャは「ボールジェスチャ」を割り当てた
        ボタンを押している間しか発火しません。

        ■ トラックボールジェスチャ（修飾キーはすべてオフ）

        \(rows)

        設定後、オレンジの「保存」を押してください。

        ─────────────────────────────

        修飾キー（Control / Shift / Option / Command）は4方向とも
        必ずオフにしてください。付けるとジェスチャ1回ごとにその修飾キーが
        押されて離され、連打として扱われます。

        Pause と Scroll Lock は使えません。Pause は macOS でキーコードを
        持たず、Scroll Lock は輝度ダウンとして横取りされます。

        Launcher が Num Lock を「Num<br/>Lock」と表示することがありますが、
        これは Launcher 側の表示上の不具合で、設定内容としては正しいです。

        Launcher を初期化した場合は、キーの割り当てだけでなく
        オクタシフトの回転も既定値に戻ります。入れ直したあと、
        メニューの「0°に戻す」で向きを合わせてください。
        """
        alert.accessoryView = setupScreenshotView()
        // An accessory app is never frontmost on its own, so the alert would
        // open behind whatever the user is looking at.
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        alert.runModal()
    }

    /// The reference screenshot, so the Launcher can be compared side by side
    /// rather than read off a list.
    private func setupScreenshotView() -> NSView? {
        guard let image = Bundle.module.image(forResource: "launcher-setup") else { return nil }

        let width: CGFloat = 560
        let height = (image.size.height / image.size.width * width).rounded()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height + 22))

        let view = NSImageView(frame: NSRect(x: 0, y: 22, width: width, height: height))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(view)

        let caption = NSTextField(labelWithString:
            "この状態が正解です。修飾キーは4つとも押されていない状態にしてください。")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.frame = NSRect(x: 0, y: 0, width: width, height: 16)
        container.addSubview(caption)

        return container
    }

    /// Shown once, on the very first launch. Everything here is discoverable
    /// from the menu afterwards, but a first run with nothing configured on the
    /// device side just looks broken otherwise.
    private func showSetupOnFirstLaunch() {
        let key = "hasShownSetup"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        showLauncherSetup()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
