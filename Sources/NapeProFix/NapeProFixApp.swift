import AppKit
import Combine
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
    private var batteryObserver: AnyCancellable?
    private var languageObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.make()
        statusItem.button?.image?.accessibilityDescription = "NapeProFix"
        statusItem.button?.imagePosition = .imageLeading

        model.start()
        rebuildMenu()

        batteryObserver = model.$batteryPercent.sink { [weak self] percent in
            self?.showBattery(percent)
        }

        // The menu and the window title are plain strings, not views, so they
        // have to be redrawn by hand. Deferred one turn because @Published
        // fires before the new value is stored, and `tr` reads the stored one.
        languageObserver = model.$language.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.rebuildMenu()
                self.settingsWindow?.title = tr("NapeProFix 設定", "NapeProFix Settings")
            }
        }

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
        let login = item(tr("ログイン時に起動", "Launch at Login"), #selector(toggleLoginItem))
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        menu.addItem(item(tr("設定を開く…", "Settings…"), #selector(openSettings)))

        let pause = item(model.isPaused
                         ? tr("一時停止を解除", "Resume")
                         : tr("一時停止（動作を全部止める）", "Pause (stop everything)"),
                         #selector(togglePause))
        pause.state = model.isPaused ? .on : .off
        menu.addItem(pause)
        menu.addItem(.separator())
        menu.addItem(item(tr("90°回す", "Rotate 90°"), #selector(rotate)))
        menu.addItem(item(tr("次のレイヤーへ", "Next Layer"), #selector(nextLayer)))
        menu.addItem(.separator())

        let status = model.isPaused ? tr("一時停止中", "Paused")
            : (model.isActive ? tr("動作中", "Running")
                : tr("アクセシビリティ権限が必要", "Accessibility permission needed"))
        let header = NSMenuItem(
            title: "NapeProFix — \(status)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let layerItem = NSMenuItem(
            title: tr("レイヤー \(model.settings.activeLayer)　/　回転補正 \(model.settings.rotation * 90)°",
                      "Layer \(model.settings.activeLayer)  /  Rotation \(model.settings.rotation * 90)°"),
            action: nil, keyEquivalent: "")
        layerItem.isEnabled = false
        menu.addItem(layerItem)

        menu.addItem(.separator())
        menu.addItem(languageMenuItem())
        menu.addItem(item(tr("終了", "Quit"), #selector(quit)))

        menu.delegate = self
        statusItem.menu = menu
    }

    /// Shown to the right of the icon, and only when there is a level to show.
    ///
    /// Monospaced digits so the item keeps its width as the number changes;
    /// a status item that shifts every few percent drags the whole menu bar
    /// along with it.
    private func showBattery(_ percent: Int?) {
        guard let button = statusItem?.button else { return }
        guard let percent else {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        button.attributedTitle = NSAttributedString(
            string: " \(percent)%",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ])
        button.image?.accessibilityDescription =
            tr("NapeProFix — 電池残量 \(percent)%", "NapeProFix — battery \(percent)%")
    }

    /// Titled in both languages, so it can be found by someone who cannot
    /// read whichever one the menu is in.
    private func languageMenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        for language in AppLanguage.allCases {
            let entry = item(language.label, #selector(chooseLanguage(_:)))
            entry.representedObject = language.rawValue
            entry.state = (language == model.language) ? .on : .off
            submenu.addItem(entry)
        }
        let parent = NSMenuItem(title: "言語 / Language", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
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
        window.title = tr("NapeProFix 設定", "NapeProFix Settings")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        model.language = language
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

extension AppDelegate: NSMenuDelegate {
    /// The five-minute poll is enough for the menu bar, but someone opening
    /// the menu is asking for the number now.
    func menuWillOpen(_ menu: NSMenu) {
        model.refreshBattery()
    }
}
