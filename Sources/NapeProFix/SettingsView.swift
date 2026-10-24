import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    /// Held out here, above the `.id` below, so changing the language from
    /// the Setup tab does not throw the window back to the first tab.
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 8) {
            TabView(selection: $tab) {
                GestureTab(model: model)
                    .tabItem { Label(tr("ジェスチャーモード", "Gesture Mode"), systemImage: "circle.circle") }
                    .tag(0)
                WheelTab(model: model)
                    .tabItem { Label(tr("スクロールモード", "Scroll Mode"), systemImage: "arrow.up.arrow.down") }
                    .tag(1)
                PointerTab(model: model)
                    .tabItem { Label(tr("ポインタ", "Pointer"), systemImage: "cursorarrow") }
                    .tag(2)
                SetupTab(model: model)
                    .tabItem { Label(tr("セットアップ", "Setup"), systemImage: "questionmark.circle") }
                    .tag(3)
            }

            Text("NapeProFix \(AppVersion.display)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(width: 640, height: 560)
        // Every string is resolved once, when its view is built, so a new
        // language needs the whole tree built again.
        .id(model.language)
    }
}

// MARK: - ジェスチャ

private struct GestureTab: View {
    @ObservedObject var model: AppModel
    @State private var editingLayer = 0

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker(tr("編集するレイヤー", "Layer to edit"), selection: $editingLayer) {
                    ForEach(0..<Settings.layerCount, id: \.self) { index in
                        Text(label(for: index)).tag(index)
                    }
                }
                .frame(width: 280)

                Spacer()

                if model.settings.activeLayer == editingLayer {
                    Label(tr("使用中", "In use"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                } else {
                    Button(tr("このレイヤーを使う", "Use this layer")) { model.settings.activeLayer = editingLayer }
                }
            }

            Divider()

            ForEach(Direction.menuOrder, id: \.self) { direction in
                DirectionRow(model: model, direction: direction, layer: editingLayer)
            }

            Divider()

            RotationRow(model: model)

            HStack {
                Text(tr("レイヤー切替", "Layer switch"))
                    .frame(width: 60, alignment: .leading)
                Text(model.settings.layerCycleShortcut?.display ?? tr("未設定", "Not set"))
                    .foregroundStyle(model.settings.layerCycleShortcut == nil
                                     ? .secondary : .primary)
                Button(tr("記録…", "Record…")) { model.recordLayerCycleShortcut() }
                if model.settings.layerCycleShortcut != nil {
                    Button(tr("削除", "Remove")) { model.clearLayerCycleShortcut() }
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(tr("登録したキーを Launcher で Nape Pro のボタン（同時押しなど）に割り当てると、"
                        + "そのボタンでレイヤーを切り替えられます。"
                        + "何も設定していないレイヤーは飛ばします。",
                        "Assign the recorded key to a Nape Pro button (or a combo press) in Launcher, "
                        + "and that button will switch layers. "
                        + "Layers with nothing assigned are skipped."))
                // Choosing this key is a trade-off the user has to make for
                // their own setup, so give them what they need to decide.
                Text(tr("このアプリは入力元のデバイスを区別できません。"
                        + "登録したキーはキーボードから直接押しても同じ動作になり、"
                        + "他のアプリからは使えなくなります。"
                        + "テンキーのキーはテンキー付きキーボードで衝突し、"
                        + "⌃⌥ + 英字はテンキーの影響を受けませんがアプリのショートカットと"
                        + "衝突しうる、という違いがあります。",
                        "This app can’t tell which device a key came from. "
                        + "Pressing the recorded key on your keyboard does the same thing, "
                        + "and other apps can no longer use it. "
                        + "Keypad keys clash on keyboards that have a numeric keypad; "
                        + "⌃⌥ + a letter avoids the keypad but may clash with "
                        + "app shortcuts."))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            GestureScrollTuning(model: model)

            Spacer()
        }
        }
        // Follow the layer in use. Switching with the shortcut while this
        // window is open otherwise leaves the picker pointing at the old
        // layer, so the rows below describe something that is not in effect.
        .onAppear { editingLayer = model.settings.activeLayer }
        .onChange(of: model.settings.activeLayer) { _, newValue in
            editingLayer = newValue
        }
    }

    private func label(for index: Int) -> String {
        var text = tr("レイヤー \(index)", "Layer \(index)")
        if index == model.settings.activeLayer { text += tr("（使用中）", " (in use)") }
        else if model.settings.layer(index).isEmpty { text += tr("（未設定）", " (empty)") }
        return text
    }
}

private struct DirectionRow: View {
    @ObservedObject var model: AppModel
    let direction: Direction
    let layer: Int

    private var config: LayerConfig { model.settings.layer(layer) }

    var body: some View {
        HStack(spacing: 10) {
            Text(direction.label)
                .frame(width: 24, alignment: .leading)
                .font(.headline)

            Picker("", selection: Binding(
                get: { config.action(for: direction) },
                set: { model.assign($0, to: direction, layer: layer) })) {
                    ForEach(GestureAction.allCases, id: \.self) { action in
                        Text(action.label).tag(action)
                    }
                }
                .labelsHidden()
                .frame(width: 220)

            if config.action(for: direction) == .shortcut {
                Text(config.shortcuts[direction]?.display ?? tr("未記録", "Not recorded"))
                    .foregroundStyle(config.shortcuts[direction] == nil ? .secondary : .primary)
                    .frame(minWidth: 70, alignment: .leading)
            }

            Button(tr("ショートカットを記録…", "Record Shortcut…")) { model.recordShortcut(for: direction, layer: layer) }
            if config.shortcuts[direction] != nil {
                Button(tr("削除", "Remove")) { model.clearShortcut(for: direction, layer: layer) }
            }
            Spacer()
        }
    }
}

private struct RotationRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tr("回転補正", "Rotation"))
                    .frame(width: 60, alignment: .leading)
                Picker("", selection: Binding(
                    get: { model.settings.rotation },
                    set: { model.setRotation($0) })) {
                        ForEach(0..<4, id: \.self) { Text("\($0 * 90)°").tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                Spacer()
            }
            Text(tr("ジェスチャの向きがズレたときに合わせます。"
                    + "Launcher を初期化するとオクタシフトも既定値に戻るので、まず 0° を試してください。",
                    "Corrects gestures that fire in the wrong direction. "
                    + "Resetting Launcher also resets Octa-Shift to its default, so try 0° first."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - ジェスチャ用スクロールの調整

/// Tuning for the scroll actions fired by discrete gestures. Lives inside the
/// gesture-mode tab because that is the only place these numbers apply;
/// scroll-mode scrolling is the device's own and passes through untouched.
private struct GestureScrollTuning: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("スクロール動作の調整（上下ジェスチャ）", "Scroll tuning (up/down gestures)")).font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(tr("スクロールの向きを反転する", "Reverse scroll direction"), isOn: Binding(
                    get: { model.settings.scrollInverted },
                    set: { model.settings.scrollInverted = $0 }))
                Text(tr("上に転がしたときに下へ動いてしまう場合に入れてください。"
                        + "ジェスチャのスクロールにだけ効きます。",
                        "Turn this on if rolling up scrolls down. "
                        + "Affects gesture scrolling only."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Picker(tr("計り方", "Measure by"), selection: Binding(
                    get: { model.settings.scrollMode },
                    set: { model.settings.scrollMode = $0 })) {
                        Text(tr("行単位", "Lines")).tag(Settings.ScrollMode.lines)
                        Text(tr("速度に応じて", "Speed")).tag(Settings.ScrollMode.velocity)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                Text(tr("ボールの移動量そのものはアプリに届かないため、「速度に応じて」は"
                        + "ジェスチャの発生間隔から転がす速さを推定し、ピクセル単位で"
                        + "加速カーブをかけます。",
                        "The app never sees how far the ball moved. “Speed” estimates "
                        + "how fast you roll from the gap between gestures, then applies "
                        + "an acceleration curve in pixels."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.settings.scrollMode == .lines {
                // The lower bound is 3, not 1: a single line per gesture looks
                // identical to the app being broken, and nothing on screen
                // points back at this setting as the cause.
                stepper(tr("1回あたり", "Per gesture"), value: Binding(
                    get: { model.settings.scrollBase },
                    set: { model.settings.scrollBase = $0 }), range: 3...40, unit: tr("行", "lines"))

                stepper(tr("連打1回ごとの増分", "Added per repeat"), value: Binding(
                    get: { model.settings.scrollStep },
                    set: { model.settings.scrollStep = $0 }), range: 0...20, unit: tr("行", "lines"))

                stepper(tr("上限", "Maximum"), value: Binding(
                    get: { model.settings.scrollMax },
                    set: { model.settings.scrollMax = $0 }), range: 1...80, unit: tr("行", "lines"))
            } else {
                stepper(tr("最小量（ゆっくり転がしたとき）", "Minimum (slow roll)"), value: Binding(
                    get: { model.settings.velocityFloor },
                    set: { model.settings.velocityFloor = $0 }),
                    range: 10...200, unit: "px", labelWidth: 220)

                HStack {
                    Text(tr("加速の強さ", "Acceleration"))
                        .frame(width: 220, alignment: .leading)
                    Slider(value: Binding(
                        get: { model.settings.velocityGain },
                        set: { model.settings.velocityGain = $0 }), in: 0.5...10)
                    .frame(width: 180)
                    Text(String(format: "%.1f", model.settings.velocityGain))
                        .monospacedDigit()
                }

                stepper(tr("上限", "Maximum"), value: Binding(
                    get: { model.settings.velocityMax },
                    set: { model.settings.velocityMax = $0 }),
                    range: 100...2000, unit: "px", labelWidth: 220)
            }

            Button(tr("既定値に戻す", "Restore Defaults")) { model.resetScrollSettings() }
        }
    }

    private func stepper(_ title: String, value: Binding<Int>,
                         range: ClosedRange<Int>, unit: String,
                         labelWidth: CGFloat = 150) -> some View {
        HStack {
            Text(title).frame(width: labelWidth, alignment: .leading)
            Stepper(value: value, in: range, step: unit == "px" ? 10 : 1) {
                Text("\(value.wrappedValue) \(unit)").monospacedDigit()
            }
            .frame(width: 140)
            Spacer()
        }
    }
}

// MARK: - スクロールモード

/// The same direction→action structure as the gesture tab, applied to the
/// device's scroll mode. Unassigned directions keep the native smooth scroll.
private struct WheelTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("スクロールモード（ボールスクロール中）の転がし方向に動作を割り当てます。"
                    + "「そのままスクロール」は回転量に比例したデバイス本来のスクロールを通します。",
                    "Assign actions to roll directions in scroll mode (while ball scrolling). "
                    + "“Scroll normally” passes through the device’s own smooth scrolling."))
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            ForEach(Direction.menuOrder, id: \.self) { direction in
                WheelDirectionRow(model: model, direction: direction)
            }

            Divider()

            HStack {
                Text(tr("動作の発火に必要な量", "Distance to trigger"))
                    .frame(width: 170, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(model.settings.wheelSpacesThreshold) },
                    set: { model.settings.wheelSpacesThreshold = Int($0) }),
                    in: 20...300)
                .frame(width: 180)
                Text("\(model.settings.wheelSpacesThreshold) px").monospacedDigit()
            }
            HStack {
                Text(tr("次の発火までの間隔", "Cooldown"))
                    .frame(width: 170, alignment: .leading)
                Slider(value: Binding(
                    get: { model.settings.wheelSpacesCooldown },
                    set: { model.settings.wheelSpacesCooldown = $0 }),
                    in: 0.2...2.0)
                .frame(width: 180)
                Text(String(format: tr("%.1f 秒", "%.1f s"), model.settings.wheelSpacesCooldown))
                    .monospacedDigit()
            }
            Text(tr("割り当てた方向は、この量まで転がしたときに1回発火します。"
                    + "その方向の通常のスクロールは無効になります。",
                    "An assigned direction fires once each time you roll this far. "
                    + "Normal scrolling in that direction is turned off."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(tr("既定値に戻す（すべて通す）", "Restore Defaults (pass everything through)")) { model.resetWheelSettings() }

            Divider()

            Text(tr("デバイス側でボールスクロールが使える状態にしてください。"
                    + "ボタンの「ボールスクロール」を押しながら転がすか、"
                    + "アドバンスモードの「常にスクロールモードを有効にする」をオンにします。"
                    + "他のマウスのスクロールにも同じ割り当てが効きます"
                    + "（入力元のデバイスを区別できないため）。",
                    "Ball scrolling must be enabled on the device. "
                    + "Either hold the button set to Ball Scroll while rolling, "
                    + "or turn on “Always enable scroll mode” in Advanced Mode. "
                    + "These assignments also apply to other mice’s scrolling "
                    + "(the app can’t tell which device input came from)."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }
}

private struct WheelDirectionRow: View {
    @ObservedObject var model: AppModel
    let direction: Direction

    /// Scroll actions are excluded: converting real scrolling into synthetic
    /// scrolling would be a no-op at best and a feedback hazard at worst.
    private static let choices: [GestureAction] = GestureAction.allCases.filter {
        $0 != .scrollUp && $0 != .scrollDown
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(direction.label)
                .frame(width: 24, alignment: .leading)
                .font(.headline)

            Picker("", selection: Binding(
                get: { model.settings.wheelActions[direction] },
                set: { model.assignWheel($0, to: direction) })) {
                    Text(tr("そのままスクロール", "Scroll normally")).tag(GestureAction?.none)
                    ForEach(Self.choices, id: \.self) { action in
                        Text(action.label).tag(GestureAction?.some(action))
                    }
                }
                .labelsHidden()
                .frame(width: 220)

            if model.settings.wheelActions[direction] == .shortcut {
                Text(model.settings.wheelShortcuts[direction]?.display ?? tr("未記録", "Not recorded"))
                    .foregroundStyle(model.settings.wheelShortcuts[direction] == nil
                                     ? .secondary : .primary)
                    .frame(minWidth: 70, alignment: .leading)
            }

            Button(tr("ショートカットを記録…", "Record Shortcut…")) { model.recordWheelShortcut(for: direction) }
            if model.settings.wheelShortcuts[direction] != nil {
                Button(tr("削除", "Remove")) { model.clearWheelShortcut(for: direction) }
            }
            Spacer()
        }
    }
}

// MARK: - ポインタ

private struct PointerTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle(tr("クリック時にカーソルを固定する", "Hold the cursor still while clicking"), isOn: Binding(
                get: { model.settings.clickFreezeEnabled },
                set: { model.settings.clickFreezeEnabled = $0 }))
                .font(.headline)

            Text(tr("ボタンを押している間カーソルを止め、離したあと元の位置に戻します。"
                    + "指がボールに触れてクリック位置がずれるのを防ぎます。",
                    "Freezes the cursor while a button is held and puts it back after release. "
                    + "Stops your finger brushing the ball from shifting the click."))
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(tr("ドラッグとみなす移動量", "Drag threshold"))
                        .frame(width: 170, alignment: .leading)
                    Stepper(value: Binding(
                        get: { model.settings.clickFreezeThreshold },
                        set: { model.settings.clickFreezeThreshold = $0 }), in: 2...40) {
                            Text("\(model.settings.clickFreezeThreshold) px").monospacedDigit()
                        }
                        .frame(width: 130)
                    Spacer()
                }
                Text(tr("押している間にこれ以上動かしたら、意図的なドラッグとみなして固定を解除します。"
                        + "小さくするとドラッグしやすく、大きくするとズレに強くなります。",
                        "Moving further than this while held counts as a deliberate drag and releases the cursor. "
                        + "Lower makes dragging easier; higher resists drift better."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(tr("離したあとの保持時間", "Hold after release"))
                        .frame(width: 170, alignment: .leading)
                    Slider(value: Binding(
                        get: { model.settings.clickFreezeHold },
                        set: { model.settings.clickFreezeHold = $0 }), in: 0...0.4)
                    .frame(width: 190)
                    Text(String(format: tr("%.2f 秒", "%.2f s"), model.settings.clickFreezeHold))
                        .monospacedDigit()
                }
                Text(tr("指を離す瞬間にもボールは動きます。ここを長くするとその分まで戻します。", "The ball moves as you lift your finger too. A longer hold undoes that movement as well."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Button(tr("既定値に戻す", "Restore Defaults")) { model.resetPointerSettings() }

            Divider()

            Text(tr("それでも全体に過敏な場合は、Keychron Launcher の DPI Settings で "
                    + "DPI を下げるほうが根本的です。このアプリはクリック時のズレだけを扱います。",
                    "If the pointer still feels too sensitive overall, lower the DPI in Keychron Launcher’s "
                    + "DPI Settings instead. This app only handles drift while clicking."))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }
}

// MARK: - セットアップ

private struct SetupTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.isActive {
                    Label(tr("動作中", "Running"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(tr("アクセシビリティ権限が必要です", "Accessibility permission needed"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button(tr("システム設定を開く", "Open System Settings")) { model.openAccessibilitySettings() }
                        Text(tr("許可すると数秒で自動的に有効になります。再起動は不要です。", "Once allowed, it turns on by itself within a few seconds. No restart needed."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Picker("言語 / Language", selection: $model.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                .frame(width: 320)

                Divider()

                Text(tr("この2つが揃っていないとジェスチャは動きません", "Gestures won’t work unless both of these are set")).font(.headline)

                Text(LocalizedStringKey(tr("**アドバンスモード**\n"
                        + "「常にジェスチャーモードを有効にする」をオンにしてください。"
                        + "オフの場合、ジェスチャは「ボールジェスチャ」を割り当てたボタンを"
                        + "押している間しか発火しません。",
                        "**Advanced Mode**\n"
                        + "Turn on “Always enable gesture mode”. "
                        + "If it’s off, gestures only fire while you hold the button "
                        + "assigned to Ball Gesture.")))

                Text(LocalizedStringKey(tr("**トラックボールジェスチャ**（修飾キーはすべてオフ）", "**Trackball Gestures** (all modifier keys off)")))
                ForEach(GestureKey.allCases, id: \.self) { key in
                    Text("　\(key.firmwareDirection.label)　→　\(key.launcherLabel)")
                        .monospaced()
                }

                if let image = Bundle.module.image(forResource: "launcher-setup") {
                    Button {
                        ImageViewer.show(image, title: tr("Launcher のトラックボールジェスチャ設定", "Launcher trackball gesture settings"))
                    } label: {
                        Image(nsImage: image)
                            .resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(.separator))
                    }
                    .buttonStyle(.plain)
                    .help(tr("クリックで別ウインドウに拡大表示", "Click to enlarge in a separate window"))

                    Text(tr("この状態が正解です。クリックすると別ウインドウで開き、"
                            + "ピンチやスクロールで拡大できます。"
                            + "設定後、オレンジの「保存」を押してください。",
                            "This is the correct setup: Up = Print Screen, Down = ÷ (keypad), "
                            + "Left = Num Lock, Right = Insert. Click to open it in a separate window, "
                            + "where you can pinch or scroll to zoom. "
                            + "When you’re done, press the orange Save button."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                Text(tr("注意点", "Notes")).font(.headline)
                Text(tr("・修飾キーを付けると、ジェスチャ1回ごとにその修飾キーが押されて離され、"
                        + "連続で転がすと連打になります。アプリ側では防げません。",
                        "• If you add a modifier key, it is pressed and released on every gesture, "
                        + "so continuous rolling taps it repeatedly. The app can’t prevent this."))
                Text(tr("・Pause と Scroll Lock は使えません。Pause は macOS でキーコードを持たず、"
                        + "Scroll Lock は輝度ダウンとして横取りされます。",
                        "• Pause and Scroll Lock don’t work. Pause has no key code on macOS, "
                        + "and macOS intercepts Scroll Lock as brightness down."))
                Text(tr("・Launcher が Num Lock を「Num<br/>Lock」と表示することがありますが、"
                        + "Launcher 側の表示上の不具合で、設定内容は正しいです。",
                        "• Launcher sometimes shows Num Lock as “Num<br/>Lock”. "
                        + "That’s a display bug in Launcher; the setting itself is correct."))
                Text(tr("・Launcher を初期化すると、キーの割り当てだけでなくオクタシフトの回転も"
                        + "既定値に戻ります。入れ直したあと回転補正を 0° にしてください。",
                        "• Resetting Launcher resets Octa-Shift rotation as well as key assignments. "
                        + "After setting the keys again, set Rotation to 0°."))

                Divider()

                HStack(spacing: 6) {
                    Text(tr("役に立ったら", "If this helped, "))
                    Link(tr("ほしい物リスト", "send the author something"),
                         destination: URL(string:
                            "https://www.amazon.co.jp/hz/wishlist/ls/WFRWJC8J65NF")!)
                    Text(tr("から何か送ってもらえると喜びます。", "from their wish list."))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
