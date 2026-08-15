import AppKit
import ServiceManagement
import SwiftUI

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
    private let model = AppModel()
    private var settingsWindow: NSWindow?
    private var observer: AnyObject?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.image?.accessibilityDescription = "NapeProFix"

        model.start()
        rebuildMenu()

        // The menu shows the active layer and rotation, so it has to follow
        // changes made in the settings window.
        observer = NotificationCenter.default.addObserver(
            forName: .init("NapeProFixSettingsChanged"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.rebuildMenu() }
            }

        showSetupOnFirstLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    // MARK: - Menu

    /// Deliberately small. Everything that needs space lives in the settings
    /// window; this is for the things worth reaching in one click.
    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Clickable items first, status last. A menu bar menu opens downward,
        // so the top is nearest the pointer; putting the read-only lines up
        // there just pushes the buttons further away.
        let login = item("ログイン時に起動", #selector(toggleLoginItem))
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(item("設定を開く…", #selector(openSettings)))

        let pause = item(model.isPaused ? "一時停止を解除" : "一時停止（動作を全部止める）",
                         #selector(togglePause))
        pause.state = model.isPaused ? .on : .off
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(item("90°回す", #selector(rotate)))
        menu.addItem(item("次のレイヤーへ", #selector(nextLayer)))
        menu.addItem(.separator())

        let status = model.isPaused ? "一時停止中"
            : (model.isActive ? "動作中" : "アクセシビリティ権限が必要")
        let header = NSMenuItem(
            title: "NapeProFix — \(status)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let layerItem = NSMenuItem(
            title: "レイヤー \(model.settings.activeLayer)　/　回転補正 \(model.settings.rotation * 90)°",
            action: nil, keyEquivalent: "")
        layerItem.isEnabled = false
        menu.addItem(layerItem)

        menu.addItem(.separator())
        menu.addItem(item("終了", #selector(quit)))

        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    // MARK: - Actions

    @objc private func rotate() {
        model.rotate()
        rebuildMenu()
    }

    @objc private func nextLayer() {
        model.settings.activeLayer =
            model.settings.nextConfiguredLayer(after: model.settings.activeLayer)
        rebuildMenu()
    }

    @objc private func openSettings() {
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(contentViewController:
            NSHostingController(rootView: SettingsView(model: model)))
        window.title = "NapeProFix 設定"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePause() {
        model.setPaused(!model.isPaused)
        rebuildMenu()
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
    }

    /// Opened once, on the very first launch. A first run with nothing
    /// configured on the device side just looks broken otherwise.
    private func showSetupOnFirstLaunch() {
        let key = "hasShownSetup"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
