import Foundation
import Testing
@testable import NapeProFix

/// The rotation baseline was measured on the device: rolling up reported
/// "left", rolling right reported "up". The firmware is a quarter turn
/// counter-clockwise from reality, so rotation 1 is the correct default.
@Test func measuredBaselineResolvesCorrectly() {
    let rotation = 1
    #expect(GestureKey.numLock.firmwareDirection.rotated(by: rotation) == .up)
    #expect(GestureKey.printScreen.firmwareDirection.rotated(by: rotation) == .right)
    #expect(GestureKey.insert.firmwareDirection.rotated(by: rotation) == .down)
    #expect(GestureKey.keypadSlash.firmwareDirection.rotated(by: rotation) == .left)
}

@Test func rotationWrapsAndIsCyclic() {
    for direction in Direction.allCases {
        #expect(direction.rotated(by: 0) == direction)
        #expect(direction.rotated(by: 4) == direction)
        #expect(direction.rotated(by: 2).rotated(by: 2) == direction)
        #expect(direction.rotated(by: -1).rotated(by: 1) == direction)
    }
}

/// The menu is listed 上下左右 for readability, but the raw values must stay
/// clockwise or the rotation arithmetic silently breaks.
@Test func menuOrderIsDisplayOnly() {
    #expect(Direction.menuOrder == [.up, .down, .left, .right])
    #expect(Direction.allCases == [.up, .right, .down, .left])
    #expect(Set(Direction.menuOrder) == Set(Direction.allCases))

    // Clockwise means one step from up is right.
    #expect(Direction.up.rotated(by: 1) == .right)
}

@Test func gestureKeysAreDistinct() {
    let directions = Set(GestureKey.allCases.map(\.firmwareDirection))
    #expect(directions.count == GestureKey.allCases.count)
}

@Test func settingsRoundTripThroughJSON() throws {
    var settings = Settings()
    settings.rotation = 3
    settings.activeLayer = 2
    settings.update(layer: 2) { $0.actions[.up] = .missionControl }
    settings.scrollBase = 12

    let decoded = try JSONDecoder().decode(
        Settings.self, from: try JSONEncoder().encode(settings))

    #expect(decoded.rotation == 3)
    #expect(decoded.activeLayer == 2)
    #expect(decoded.current.action(for: .up) == .missionControl)
    #expect(decoded.layer(0).action(for: .left) == .spaceLeft)
    #expect(decoded.scrollBase == 12)
}

@Test func shortcutsSurviveEncoding() throws {
    var settings = Settings()
    settings.update(layer: 1) {
        $0.actions[.right] = .shortcut
        $0.shortcuts[.right] = Shortcut(keyCode: 40, modifiers: 1_048_576, display: "⌘K")
    }

    let decoded = try JSONDecoder().decode(
        Settings.self, from: try JSONEncoder().encode(settings))

    #expect(decoded.layer(1).action(for: .right) == .shortcut)
    #expect(decoded.layer(1).shortcuts[.right]?.keyCode == 40)
    // A recorded shortcut is what the menu should show, not the enum name.
    #expect(decoded.layer(1).label(for: .right) == "⌘K")
    #expect(decoded.layer(0).label(for: .up) == "スクロール（上）")
}

/// Settings saved before layers existed must migrate into layer 0 rather than
/// silently reverting the user's assignments to defaults.
@Test func migratesPreLayerSettings() throws {
    // Swift encodes Int-keyed dictionaries as objects with stringified keys.
    let json = """
    {"rotation":2,"actions":{"0":"missionControl","3":"browserBack"},
     "shortcuts":{"1":{"keyCode":40,"modifiers":1048576,"display":"⌘K"}},
     "scrollBase":8,"scrollStep":5,"scrollMax":32,"scrollWindow":0.4}
    """
    let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))

    #expect(decoded.rotation == 2)
    #expect(decoded.activeLayer == 0)
    #expect(decoded.layer(0).action(for: .up) == .missionControl)
    #expect(decoded.layer(0).action(for: .left) == .browserBack)
    #expect(decoded.layer(0).shortcuts[.right]?.display == "⌘K")
}

@Test func scrollModeSurvivesEncodingAndDefaultsToLines() throws {
    var settings = Settings()
    #expect(settings.scrollMode == .lines)
    settings.scrollMode = .velocity
    settings.velocityFloor = 60
    settings.velocityGain = 5.0

    let decoded = try JSONDecoder().decode(
        Settings.self, from: try JSONEncoder().encode(settings))
    #expect(decoded.scrollMode == .velocity)
    #expect(decoded.velocityFloor == 60)
    #expect(decoded.velocityGain == 5.0)

    // Settings saved before the mode existed must stay in line mode.
    let old = try JSONDecoder().decode(
        Settings.self, from: Data(#"{"rotation":1,"scrollBase":8}"#.utf8))
    #expect(old.scrollMode == .lines)
    #expect(old.velocityFloor == 40)
}

@Test func wheelRoutingSurvivesEncoding() throws {
    var settings = Settings()
    #expect(settings.wheelActions.isEmpty)   // passthrough is the default
    settings.wheelActions[.left] = .spaceLeft
    settings.wheelActions[.up] = .shortcut
    settings.wheelShortcuts[.up] = Shortcut(keyCode: 40, modifiers: 0, display: "K")
    settings.wheelSpacesThreshold = 100

    let decoded = try JSONDecoder().decode(
        Settings.self, from: try JSONEncoder().encode(settings))
    #expect(decoded.wheelActions[.left] == .spaceLeft)
    #expect(decoded.wheelActions[.up] == .shortcut)
    #expect(decoded.wheelShortcuts[.up]?.display == "K")
    #expect(decoded.wheelActions[.down] == nil)
    #expect(decoded.wheelSpacesThreshold == 100)

    // Settings saved before the feature existed must not hijack scrolling.
    let old = try JSONDecoder().decode(
        Settings.self, from: Data(#"{"rotation":1,"scrollBase":8}"#.utf8))
    #expect(old.wheelActions.isEmpty)
}

/// 1.4.0 stored a single toggle; it must migrate into per-direction routing —
/// once. A deliberately cleared routing must not resurrect it.
@Test func migratesWheelSpacesToggle() throws {
    let old = try JSONDecoder().decode(Settings.self, from: Data(
        #"{"rotation":1,"wheelSpacesEnabled":true}"#.utf8))
    #expect(old.wheelActions[.left] == .spaceLeft)
    #expect(old.wheelActions[.right] == .spaceRight)

    var cleared = old
    cleared.wheelActions = [:]
    let decoded = try JSONDecoder().decode(
        Settings.self, from: try JSONEncoder().encode(cleared))
    #expect(decoded.wheelActions.isEmpty)
}

@Test func scrollInversionSurvivesEncoding() throws {
    var settings = Settings()
    #expect(settings.scrollInverted == false)
    settings.scrollInverted = true

    let decoded = try JSONDecoder().decode(
        Settings.self, from: try JSONEncoder().encode(settings))
    #expect(decoded.scrollInverted == true)

    // Settings saved before the switch existed must not come back inverted.
    let old = try JSONDecoder().decode(
        Settings.self, from: Data(#"{"rotation":1,"scrollBase":8}"#.utf8))
    #expect(old.scrollInverted == false)
}

@Test func clickFreezeSettingsSurviveEncoding() throws {
    var settings = Settings()
    settings.clickFreezeEnabled = false
    settings.clickFreezeThreshold = 20
    settings.clickFreezeHold = 0.3

    let decoded = try JSONDecoder().decode(
        Settings.self, from: try JSONEncoder().encode(settings))

    #expect(decoded.clickFreezeEnabled == false)
    #expect(decoded.clickFreezeThreshold == 20)
    #expect(decoded.clickFreezeHold == 0.3)
}

/// Settings saved before click freeze existed must load with it enabled,
/// not with a zero threshold that would pin the cursor on every click.
@Test func decodesSettingsWithoutClickFreeze() throws {
    let json = #"{"rotation":1,"activeLayer":0,"scrollBase":8}"#
    let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))

    #expect(decoded.clickFreezeEnabled == true)
    #expect(decoded.clickFreezeThreshold == 8)
    #expect(decoded.clickFreezeHold == 0.12)
}

@Test func layerCycleSkipsEmptyLayers() {
    var settings = Settings()
    settings.update(layer: 3) { $0.actions[.up] = .missionControl }

    // 0 and 3 are configured; the rest are empty and should be skipped.
    #expect(settings.nextConfiguredLayer(after: 0) == 3)
    #expect(settings.nextConfiguredLayer(after: 3) == 0)
}

@Test func layerCycleStaysPutWhenOnlyOneLayerIsSet() {
    let settings = Settings()
    #expect(settings.nextConfiguredLayer(after: 0) == 0)
}

// MARK: - Event snapshot

/// The taps read a snapshot, never Settings. If the snapshot stopped
/// reflecting a setting, the feature would silently stop working.
@Test func snapshotCarriesTheResolvedLayer() {
    var settings = Settings()
    settings.activeLayer = 2
    settings.rotation = 3
    settings.update(layer: 2) {
        $0.actions[.up] = .missionControl
        $0.actions[.down] = .shortcut
        $0.shortcuts[.down] = Shortcut(keyCode: 40, modifiers: 1_048_576, display: "⌘K")
    }

    let snap = EventSnapshot(settings)
    #expect(snap.rotation == 3)
    #expect(snap.gestureActions[.up] == .missionControl)
    #expect(snap.gestureKeys[.down]?.keyCode == 40)
    #expect(snap.gestureKeys[.up] == nil)
}

/// The scroll tap is switched off entirely when nothing is routed, so an
/// unconfigured install keeps every scroll event out of this process.
@Test func snapshotReportsWheelRoutingInactiveByDefault() {
    #expect(EventSnapshot(Settings()).wheelRoutingActive == false)

    var settings = Settings()
    settings.wheelActions[.left] = .spaceLeft
    let snap = EventSnapshot(settings)
    #expect(snap.wheelRoutingActive == true)
    #expect(snap.wheelActions[.left] == .spaceLeft)
    #expect(snap.wheelActions[.up] == nil)
}

@Test func dir4SubscriptsEveryDirection() {
    var values = Dir4<Int>(repeating: 0)
    for (index, direction) in Direction.allCases.enumerated() {
        values[direction] = index
    }
    for (index, direction) in Direction.allCases.enumerated() {
        #expect(values[direction] == index)
    }
}
