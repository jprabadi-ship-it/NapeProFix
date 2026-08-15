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

    /// How gesture scrolling is measured.
    ///
    /// The ball's actual travel never reaches this app — gesture mode sends
    /// only direction keys. What does scale with rolling speed is how often
    /// those keys arrive, so `velocity` estimates speed from the interval
    /// between events and scrolls in pixels along an accelerating curve.
    enum ScrollMode: String, Codable {
        case lines      // fixed lines per gesture, streak-based boost
        case velocity   // pixels per gesture, scaled by event rate
    }

    var scrollMode: ScrollMode = .lines

    var scrollBase = 8
    var scrollStep = 5
    var scrollMax = 32
    var scrollWindow: TimeInterval = 0.4

    /// Velocity mode: pixels for a single, unhurried gesture.
    var velocityFloor = 40
    /// Velocity mode: acceleration strength. Scroll per event grows with the
    /// square of the event rate, scaled by this.
    var velocityGain: Double = 3.0
    /// Velocity mode: cap in pixels per event, so a fast spin stays bounded.
    var velocityMax = 600
    /// Flips which way the content moves for a given roll direction. Separate
    /// from macOS's own natural-scrolling setting, so this can be corrected
    /// for the trackball without changing the rest of the system.
    var scrollInverted = false

    /// Scroll-mode routing: what each roll direction does while the device is
    /// in ball-scroll mode (real, proportional scroll events).
    ///
    /// A direction with no entry passes through untouched — the smooth native
    /// scrolling is the whole point of scroll mode, so passthrough is the
    /// default, not an action.
    var wheelActions: [Direction: GestureAction] = [:]
    var wheelShortcuts: [Direction: Shortcut] = [:]

    /// Kept only to migrate settings from 1.4.0, which had a single
    /// "horizontal roll switches spaces" toggle instead of per-direction routing.
    var wheelSpacesEnabled = false
    /// Accumulated pixels in one direction that trigger the assigned action.
    var wheelSpacesThreshold = 60
    /// Seconds before the same direction may fire again.
    var wheelSpacesCooldown: TimeInterval = 0.6

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
        case scrollMode, velocityFloor, velocityGain, velocityMax
        case wheelSpacesEnabled, wheelSpacesThreshold, wheelSpacesCooldown
        case wheelActions, wheelShortcuts
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
        scrollMode = try c.decodeIfPresent(ScrollMode.self, forKey: .scrollMode)
            ?? defaults.scrollMode
        velocityFloor = try c.decodeIfPresent(Int.self, forKey: .velocityFloor)
            ?? defaults.velocityFloor
        velocityGain = try c.decodeIfPresent(Double.self, forKey: .velocityGain)
            ?? defaults.velocityGain
        velocityMax = try c.decodeIfPresent(Int.self, forKey: .velocityMax)
            ?? defaults.velocityMax
        wheelSpacesEnabled = try c.decodeIfPresent(Bool.self, forKey: .wheelSpacesEnabled)
            ?? defaults.wheelSpacesEnabled
        wheelSpacesThreshold = try c.decodeIfPresent(Int.self, forKey: .wheelSpacesThreshold)
            ?? defaults.wheelSpacesThreshold
        wheelSpacesCooldown = try c.decodeIfPresent(TimeInterval.self, forKey: .wheelSpacesCooldown)
            ?? defaults.wheelSpacesCooldown

        if let rawWheel = try c.decodeIfPresent([Int: GestureAction].self, forKey: .wheelActions) {
            for (key, value) in rawWheel {
                if let dir = Direction(rawValue: key) { wheelActions[dir] = value }
            }
        } else if wheelSpacesEnabled {
            // 1.4.0 had a single toggle: horizontal roll switched spaces.
            wheelActions = [.left: .spaceLeft, .right: .spaceRight]
        }
        for (key, value) in try c.decodeIfPresent([Int: Shortcut].self, forKey: .wheelShortcuts) ?? [:] {
            if let dir = Direction(rawValue: key) { wheelShortcuts[dir] = value }
        }
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
        try c.encode(scrollMode, forKey: .scrollMode)
        try c.encode(velocityFloor, forKey: .velocityFloor)
        try c.encode(velocityGain, forKey: .velocityGain)
        try c.encode(velocityMax, forKey: .velocityMax)
        try c.encode(wheelSpacesEnabled, forKey: .wheelSpacesEnabled)
        try c.encode(wheelSpacesThreshold, forKey: .wheelSpacesThreshold)
        try c.encode(wheelSpacesCooldown, forKey: .wheelSpacesCooldown)
        var rawWheel: [Int: GestureAction] = [:]
        for (dir, value) in wheelActions { rawWheel[dir.rawValue] = value }
        try c.encode(rawWheel, forKey: .wheelActions)
        var rawWheelShortcuts: [Int: Shortcut] = [:]
        for (dir, value) in wheelShortcuts { rawWheelShortcuts[dir.rawValue] = value }
        try c.encode(rawWheelShortcuts, forKey: .wheelShortcuts)
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
