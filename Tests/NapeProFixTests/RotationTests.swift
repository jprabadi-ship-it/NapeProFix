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
