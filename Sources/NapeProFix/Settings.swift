import Foundation

/// One layer's worth of gesture assignments.
struct LayerConfig: Codable {
    var actions: [Direction: GestureAction] = [:]
    var shortcuts: [Direction: Shortcut] = [:]

    // Direction is not a String key, so the dictionaries need a codable form.
    private enum CodingKeys: String, CodingKey { case actions, shortcuts }

    init(actions: [Direction: GestureAction] = [:],
         shortcuts: [Direction: Shortcut] = [:]) {
        self.actions = actions
        self.shortcuts = shortcuts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        for (key, value) in try c.decodeIfPresent([Int: GestureAction].self, forKey: .actions) ?? [:] {
            if let dir = Direction(rawValue: key) { actions[dir] = value }
        }
        for (key, value) in try c.decodeIfPresent([Int: Shortcut].self, forKey: .shortcuts) ?? [:] {
            if let dir = Direction(rawValue: key) { shortcuts[dir] = value }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var rawActions: [Int: GestureAction] = [:]
        for (dir, value) in actions { rawActions[dir.rawValue] = value }
        try c.encode(rawActions, forKey: .actions)

        var rawShortcuts: [Int: Shortcut] = [:]
        for (dir, value) in shortcuts { rawShortcuts[dir.rawValue] = value }
        try c.encode(rawShortcuts, forKey: .shortcuts)
    }

    func action(for direction: Direction) -> GestureAction {
        actions[direction] ?? .none
    }

    /// A recorded shortcut reads better in the menu than the word "ショートカット".
    func label(for direction: Direction) -> String {
        let action = self.action(for: direction)
        if action == .shortcut, let shortcut = shortcuts[direction] {
            return shortcut.display
        }
        return action.label
    }

    var isEmpty: Bool {
        actions.values.allSatisfy { $0 == .none }
    }
}

struct Settings: Codable {
    static let layerCount = 8

    /// 0-3, in 90 degree steps. Added to the direction the firmware reports.
    ///
    /// OctaShift occasionally resets and leaves the gestures rotated. Nothing
    /// here can prevent that, so this exists to make recovery a single click
    /// instead of a trip back into the Launcher.
    var rotation: Int = 1

    /// The device never tells us which of its own layers is selected — only
    /// key codes arrive — so the layer is state kept on this side, switched
    /// from the menu or by `layerCycleShortcut`.
    var activeLayer: Int = 0

    var layers: [Int: LayerConfig] = [
        0: LayerConfig(actions: [
            .up: .scrollUp,
            .down: .scrollDown,
            .left: .spaceLeft,
            .right: .spaceRight,
        ])
    ]

    /// Cycles to the next layer that has anything assigned. Meant to be put on
    /// a Nape Pro button so switching feels like the device's own layers.
    var layerCycleShortcut: Shortcut?

    var scrollBase = 8
    var scrollStep = 5
    var scrollMax = 32
    var scrollWindow: TimeInterval = 0.4
    /// Flips which way the content moves for a given roll direction. Separate
    /// from macOS's own natural-scrolling setting, so this can be corrected
    /// for the trackball without changing the rest of the system.
    var scrollInverted = false

    /// Hold the cursor still while a mouse button is down, so a click lands
    /// where it was aimed rather than where the ball drifted to.
    var clickFreezeEnabled = true
    /// Pixels of movement during the press that count as a deliberate drag.
    var clickFreezeThreshold = 8
    /// Seconds to stay frozen after the button is released.
    var clickFreezeHold: TimeInterval = 0.12

    private enum CodingKeys: String, CodingKey {
        case rotation, activeLayer, layers, layerCycleShortcut
        case scrollBase, scrollStep, scrollMax, scrollWindow, scrollInverted
        case clickFreezeEnabled, clickFreezeThreshold, clickFreezeHold
        // Pre-layer format, still read so existing settings survive.
        case actions, shortcuts
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? defaults.rotation
        activeLayer = try c.decodeIfPresent(Int.self, forKey: .activeLayer) ?? 0
        scrollBase = try c.decodeIfPresent(Int.self, forKey: .scrollBase) ?? defaults.scrollBase
        scrollStep = try c.decodeIfPresent(Int.self, forKey: .scrollStep) ?? defaults.scrollStep
        scrollMax = try c.decodeIfPresent(Int.self, forKey: .scrollMax) ?? defaults.scrollMax
        scrollWindow = try c.decodeIfPresent(TimeInterval.self, forKey: .scrollWindow)
            ?? defaults.scrollWindow
        scrollInverted = try c.decodeIfPresent(Bool.self, forKey: .scrollInverted)
            ?? defaults.scrollInverted
        layerCycleShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .layerCycleShortcut)
        clickFreezeEnabled = try c.decodeIfPresent(Bool.self, forKey: .clickFreezeEnabled)
            ?? defaults.clickFreezeEnabled
        clickFreezeThreshold = try c.decodeIfPresent(Int.self, forKey: .clickFreezeThreshold)
            ?? defaults.clickFreezeThreshold
        clickFreezeHold = try c.decodeIfPresent(TimeInterval.self, forKey: .clickFreezeHold)
            ?? defaults.clickFreezeHold

        if let stored = try c.decodeIfPresent([Int: LayerConfig].self, forKey: .layers),
           !stored.isEmpty {
            layers = stored
        } else {
            // Migrate a flat pre-layer configuration into layer 0.
            var migrated = LayerConfig()
            for (key, value) in try c.decodeIfPresent([Int: GestureAction].self, forKey: .actions) ?? [:] {
                if let dir = Direction(rawValue: key) { migrated.actions[dir] = value }
            }
            for (key, value) in try c.decodeIfPresent([Int: Shortcut].self, forKey: .shortcuts) ?? [:] {
                if let dir = Direction(rawValue: key) { migrated.shortcuts[dir] = value }
            }
            layers = migrated.isEmpty ? defaults.layers : [0: migrated]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(activeLayer, forKey: .activeLayer)
        try c.encode(layers, forKey: .layers)
        try c.encodeIfPresent(layerCycleShortcut, forKey: .layerCycleShortcut)
        try c.encode(scrollBase, forKey: .scrollBase)
        try c.encode(scrollStep, forKey: .scrollStep)
        try c.encode(scrollMax, forKey: .scrollMax)
        try c.encode(scrollWindow, forKey: .scrollWindow)
        try c.encode(scrollInverted, forKey: .scrollInverted)
        try c.encode(clickFreezeEnabled, forKey: .clickFreezeEnabled)
        try c.encode(clickFreezeThreshold, forKey: .clickFreezeThreshold)
        try c.encode(clickFreezeHold, forKey: .clickFreezeHold)
    }

    func layer(_ index: Int) -> LayerConfig {
        layers[index] ?? LayerConfig()
    }

    var current: LayerConfig { layer(activeLayer) }

    mutating func update(layer index: Int, _ body: (inout LayerConfig) -> Void) {
        var config = layer(index)
        body(&config)
        layers[index] = config
    }

    /// Skips layers with nothing on them, so cycling stays useful when only a
    /// couple are set up.
    func nextConfiguredLayer(after index: Int) -> Int {
        for step in 1...Settings.layerCount {
            let candidate = (index + step) % Settings.layerCount
            if !layer(candidate).isEmpty { return candidate }
        }
        return index
    }
}

enum SettingsStore {
    private static let key = "settings"

    static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return settings
    }

    static func save(_ settings: Settings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
