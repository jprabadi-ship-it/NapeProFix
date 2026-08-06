import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            TabView {
                GestureTab(model: model)
                    .tabItem { Label("ジェスチャ", systemImage: "circle.circle") }
                ScrollTab(model: model)
                    .tabItem { Label("スクロール", systemImage: "arrow.up.arrow.down") }
                PointerTab(model: model)
                    .tabItem { Label("ポインタ", systemImage: "cursorarrow") }
                SetupTab(model: model)
                    .tabItem { Label("セットアップ", systemImage: "questionmark.circle") }
            }

            Text("NapeProFix \(AppVersion.display)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(width: 640, height: 560)
    }
}

// MARK: - ジェスチャ

private struct GestureTab: View {
    @ObservedObject var model: AppModel
    @State private var editingLayer = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("編集するレイヤー", selection: $editingLayer) {
                    ForEach(0..<Settings.layerCount, id: \.self) { index in
                        Text(label(for: index)).tag(index)
                    }
                }
                .frame(width: 280)

                Spacer()

                if model.settings.activeLayer == editingLayer {
                    Label("使用中", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                } else {
                    Button("このレイヤーを使う") { model.settings.activeLayer = editingLayer }
                }
            }

            Divider()

            ForEach(Direction.menuOrder, id: \.self) { direction in
                DirectionRow(model: model, direction: direction, layer: editingLayer)
            }

            Divider()

            RotationRow(model: model)

            HStack {
                Text("レイヤー切替")
                    .frame(width: 60, alignment: .leading)
                Text(model.settings.layerCycleShortcut?.display ?? "未設定")
                    .foregroundStyle(model.settings.layerCycleShortcut == nil
                                     ? .secondary : .primary)
                Button("記録…") { model.recordLayerCycleShortcut() }
                if model.settings.layerCycleShortcut != nil {
                    Button("削除") { model.clearLayerCycleShortcut() }
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("登録したキーを Launcher で Nape Pro のボタン（同時押しなど）に割り当てると、"
                     + "そのボタンでレイヤーを切り替えられます。"
                     + "何も設定していないレイヤーは飛ばします。")
                // Choosing this key is a trade-off the user has to make for
                // their own setup, so give them what they need to decide.
                Text("このアプリは入力元のデバイスを区別できません。"
                     + "登録したキーはキーボードから直接押しても同じ動作になり、"
                     + "他のアプリからは使えなくなります。"
                     + "テンキーのキーはテンキー付きキーボードで衝突し、"
                     + "⌃⌥ + 英字はテンキーの影響を受けませんがアプリのショートカットと"
                     + "衝突しうる、という違いがあります。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
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
        var text = "レイヤー \(index)"
        if index == model.settings.activeLayer { text += "（使用中）" }
        else if model.settings.layer(index).isEmpty { text += "（未設定）" }
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
                Text(config.shortcuts[direction]?.display ?? "未記録")
                    .foregroundStyle(config.shortcuts[direction] == nil ? .secondary : .primary)
                    .frame(minWidth: 70, alignment: .leading)
            }

            Button("ショートカットを記録…") { model.recordShortcut(for: direction, layer: layer) }
            if config.shortcuts[direction] != nil {
                Button("削除") { model.clearShortcut(for: direction, layer: layer) }
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
                Text("回転補正")
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
            Text("ジェスチャの向きがズレたときに合わせます。"
                 + "Launcher を初期化するとオクタシフトも既定値に戻るので、まず 0° を試してください。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - スクロール

private struct ScrollTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("ジェスチャは離散的なので、短い間隔で続けて転がすほど1回あたりの量を伸ばします。")
                .font(.callout)
                .foregroundStyle(.secondary)

            // The lower bound is 3, not 1: a single line per gesture looks
            // identical to the app being broken, and nothing on screen points
            // back at this setting as the cause.
            stepper("1回あたり", value: Binding(
                get: { model.settings.scrollBase },
                set: { model.settings.scrollBase = $0 }), range: 3...40, unit: "行")

            stepper("連打1回ごとの増分", value: Binding(
                get: { model.settings.scrollStep },
                set: { model.settings.scrollStep = $0 }), range: 0...20, unit: "行")

            stepper("上限", value: Binding(
                get: { model.settings.scrollMax },
                set: { model.settings.scrollMax = $0 }), range: 1...80, unit: "行")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("連打とみなす間隔")
                        .frame(width: 150, alignment: .leading)
                    Slider(value: Binding(
                        get: { model.settings.scrollWindow },
                        set: { model.settings.scrollWindow = $0 }), in: 0.1...1.0)
                    .frame(width: 200)
                    Text(String(format: "%.2f 秒", model.settings.scrollWindow))
                        .monospacedDigit()
                }
                Text("これより短い間隔で続いた場合を「連続」とみなします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("既定値に戻す") { model.resetScrollSettings() }

            Spacer()
        }
    }

    private func stepper(_ title: String, value: Binding<Int>,
                         range: ClosedRange<Int>, unit: String) -> some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue) \(unit)").monospacedDigit()
            }
            .frame(width: 140)
            Spacer()
        }
    }
}

// MARK: - ポインタ

private struct PointerTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("クリック時にカーソルを固定する", isOn: Binding(
                get: { model.settings.clickFreezeEnabled },
                set: { model.settings.clickFreezeEnabled = $0 }))
                .font(.headline)

            Text("ボタンを押している間カーソルを止め、離したあと元の位置に戻します。"
                 + "指がボールに触れてクリック位置がずれるのを防ぎます。")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("ドラッグとみなす移動量")
                        .frame(width: 170, alignment: .leading)
                    Stepper(value: Binding(
                        get: { model.settings.clickFreezeThreshold },
                        set: { model.settings.clickFreezeThreshold = $0 }), in: 2...40) {
                            Text("\(model.settings.clickFreezeThreshold) px").monospacedDigit()
                        }
                        .frame(width: 130)
                    Spacer()
                }
                Text("押している間にこれ以上動かしたら、意図的なドラッグとみなして固定を解除します。"
                     + "小さくするとドラッグしやすく、大きくするとズレに強くなります。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("離したあとの保持時間")
                        .frame(width: 170, alignment: .leading)
                    Slider(value: Binding(
                        get: { model.settings.clickFreezeHold },
                        set: { model.settings.clickFreezeHold = $0 }), in: 0...0.4)
                    .frame(width: 190)
                    Text(String(format: "%.2f 秒", model.settings.clickFreezeHold))
                        .monospacedDigit()
                }
                Text("指を離す瞬間にもボールは動きます。ここを長くするとその分まで戻します。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Button("既定値に戻す") { model.resetPointerSettings() }

            Divider()

            Text("それでも全体に過敏な場合は、Keychron Launcher の DPI Settings で "
                 + "DPI を下げるほうが根本的です。このアプリはクリック時のズレだけを扱います。")
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
                    Label("動作中", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("アクセシビリティ権限が必要です", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("システム設定を開く") { model.openAccessibilitySettings() }
                        Text("許可すると数秒で自動的に有効になります。再起動は不要です。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Divider()

                Text("この2つが揃っていないとジェスチャは動きません").font(.headline)

                Text("**アドバンスモード**\n"
                     + "「常にジェスチャーモードを有効にする」をオンにしてください。"
                     + "オフの場合、ジェスチャは「ボールジェスチャ」を割り当てたボタンを"
                     + "押している間しか発火しません。")

                Text("**トラックボールジェスチャ**（修飾キーはすべてオフ）")
                ForEach(GestureKey.allCases, id: \.self) { key in
                    Text("　\(key.firmwareDirection.label)　→　\(key.launcherLabel)")
                        .monospaced()
                }

                if let image = Bundle.module.image(forResource: "launcher-setup") {
                    Button {
                        ImageViewer.show(image, title: "Launcher のトラックボールジェスチャ設定")
                    } label: {
                        Image(nsImage: image)
                            .resizable().scaledToFit()
                            .frame(maxWidth: .infinity)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(.separator))
                    }
                    .buttonStyle(.plain)
                    .help("クリックで別ウインドウに拡大表示")

                    Text("この状態が正解です。クリックすると別ウインドウで開き、"
                         + "ピンチやスクロールで拡大できます。"
                         + "設定後、オレンジの「保存」を押してください。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                Text("注意点").font(.headline)
                Text("・修飾キーを付けると、ジェスチャ1回ごとにその修飾キーが押されて離され、"
                     + "連続で転がすと連打になります。アプリ側では防げません。")
                Text("・Pause と Scroll Lock は使えません。Pause は macOS でキーコードを持たず、"
                     + "Scroll Lock は輝度ダウンとして横取りされます。")
                Text("・Launcher が Num Lock を「Num<br/>Lock」と表示することがありますが、"
                     + "Launcher 側の表示上の不具合で、設定内容は正しいです。")
                Text("・Launcher を初期化すると、キーの割り当てだけでなくオクタシフトの回転も"
                     + "既定値に戻ります。入れ直したあと回転補正を 0° にしてください。")

                Divider()

                HStack(spacing: 6) {
                    Text("役に立ったら")
                    Link("ほしい物リスト",
                         destination: URL(string:
                            "https://www.amazon.co.jp/hz/wishlist/ls/WFRWJC8J65NF")!)
                    Text("から何か送ってもらえると喜びます。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
