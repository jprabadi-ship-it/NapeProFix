// GigowatUpdater.swift — gigowat.com で配布している Mac アプリの起動時の更新。
//
// 原本: ~/総合/GigowatUpdater/GigowatUpdater.swift（各アプリへは sync.sh で写す。写しを直接直さない）
//
// 使い方（アプリの起動処理の最後に1行）:
//     GigowatUpdater.shared.checkOnLaunch(slug: "elgotune")
// メニューから手動で確かめるとき:
//     GigowatUpdater.shared.checkNow()
//
// 流れ:
//   1. https://gigowat.com/updates/<slug>.json（gigowat-updates が作る台帳）を読む
//   2. 新しい版があれば、インストールするかを聞く
//   3. 「インストール」なら dmg を落とし、sha256・署名（同じ Team ID・同じバンドル ID・公証済み）・版を確かめる
//   4. アプリを終了し、終了を待った補助スクリプトが今のアプリを差し替えて open で起動し直す
// 書き込めない場所・dmg の中・App Translocation から動いているとき、または確認が合わないときは上書きせずに知らせる。
//
// 試験用: defaults write <バンドルID> GigowatUpdaterManifestURL "file:///.../test.json" で台帳を差し替えられる。

import AppKit
import CryptoKit
import Foundation
import Security

@MainActor
public final class GigowatUpdater: NSObject {
    public static let shared = GigowatUpdater()

    private let skipKey = "GigowatUpdaterSkippedVersion"
    private let manifestOverrideKey = "GigowatUpdaterManifestURL"
    private var slug = ""
    private var busy = false
    private var progressPanel: NSPanel?
    private var progressBar: NSProgressIndicator?
    private var progressLabel: NSTextField?
    private var downloadTask: URLSessionDownloadTask?
    private var cancelled = false

    struct Manifest: Decodable, Sendable {
        let app: String?
        let version: String
        let url: String
        let sha256: String
        let size: Int?
        let notes: String?
        let page: String?
    }

    struct UpdateError: Error {
        let message: String
        init(_ m: String) { message = m }
    }

    // MARK: - 入口

    /// 起動時に一度だけ呼ぶ。数秒待ってから静かに確かめ、新しい版があるときだけ聞く。
    public func checkOnLaunch(slug: String, delay: TimeInterval = 4) {
        self.slug = slug
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self.check(userInitiated: false)
        }
    }

    /// メニューの「アップデートを確認…」から呼ぶ。最新のときもそう知らせる。
    public func checkNow(slug: String? = nil) {
        if let slug { self.slug = slug }
        Task { @MainActor in await self.check(userInitiated: true) }
    }

    // MARK: - 確認

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
    }

    private var manifestURL: URL? {
        if let s = UserDefaults.standard.string(forKey: manifestOverrideKey), let u = URL(string: s) { return u }
        guard !slug.isEmpty else { return nil }
        return URL(string: "https://gigowat.com/updates/\(slug).json")
    }

    /// App Store の版やサンドボックスの中では自分を入れ替えてはいけない（ストアの規約・権限の両方）
    private var isStoreOrSandboxed: Bool {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil { return true }
        if let r = Bundle.main.appStoreReceiptURL, FileManager.default.fileExists(atPath: r.path) { return true }
        return false
    }

    private func check(userInitiated: Bool) async {
        guard !busy, !isStoreOrSandboxed, let url = manifestURL else { return }
        busy = true
        defer { busy = false }
        let manifest: Manifest
        do {
            manifest = try await Self.fetchManifest(url)
        } catch {
            log("台帳を読めませんでした: \(error)")
            if userInitiated { inform(gwL("更新を確かめられませんでした", "Couldn’t check for updates"), gwL("ネットワークの接続を確かめて、あとでもう一度お試しください。", "Check your network connection and try again later.")) }
            return
        }
        guard Self.compare(manifest.version, currentVersion) > 0 else {
            if userInitiated { inform(gwL("最新の版です", "You’re up to date"), gwL("\(appName) \(currentVersion) は最新の版です。", "\(appName) \(currentVersion) is the latest version.")) }
            return
        }
        if !userInitiated, UserDefaults.standard.string(forKey: skipKey) == manifest.version { return }
        log("新しい版 \(manifest.version) を見つけました")

        if let problem = locationProblem() {
            log("置き場所の都合で入れ替えられません: \(Bundle.main.bundleURL.path)")
            let a = makeAlert(gwL("\(appName) \(manifest.version) が出ています", "\(appName) \(manifest.version) is available"),
                              gwL("いまお使いの版は \(currentVersion) です。\n\n\(problem)", "You have \(currentVersion).\n\n\(problem)"))
            a.addButton(withTitle: gwL("配布ページを開く", "Open Download Page"))
            a.addButton(withTitle: gwL("閉じる", "Close"))
            if run(a) == .alertFirstButtonReturn, let p = manifest.page, let u = URL(string: p) { NSWorkspace.shared.open(u) }
            return
        }

        let a = makeAlert(gwL("\(appName) の新しい版 \(manifest.version) が出ています", "A new version of \(appName) (\(manifest.version)) is available"),
                          gwL("いまお使いの版は \(currentVersion) です。ダウンロードしてインストールしますか？\nインストールすると \(appName) をいったん終了し、新しい版で起動し直します。",
                            "You have \(currentVersion). Download and install it now?\n\(appName) will quit and reopen with the new version."))
        if let notes = manifest.notes, !notes.isEmpty { a.accessoryView = notesView(notes) }
        a.addButton(withTitle: gwL("インストール", "Install"))
        a.addButton(withTitle: gwL("あとで", "Later"))
        a.addButton(withTitle: gwL("この版はスキップ", "Skip This Version"))
        switch run(a) {
        case .alertFirstButtonReturn:
            await install(manifest)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(manifest.version, forKey: skipKey)
        default:
            break
        }
    }

    nonisolated private static func fetchManifest(_ url: URL) async throws -> Manifest {
        if url.isFileURL { return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        req.setValue("GigowatUpdater", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession(configuration: .ephemeral).data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    /// 1.10.2 と 1.9 のように数字の区切りごとに比べる。
    nonisolated static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] { s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }

    /// 差し替えられない置き場所なら、その理由を返す。
    private func locationProblem() -> String? {
        let path = Bundle.main.bundleURL.path
        if path.contains("/AppTranslocation/") {
            return gwL("いまのアプリは macOS が一時的な場所に移して動かしているため、自動で入れ替えられません。\(appName) を「アプリケーション」フォルダへ移してから起動し直すか、配布ページから新しい版を入れてください。",
                     "macOS is running this copy from a temporary location, so it can’t be replaced automatically. Move \(appName) to the Applications folder and reopen it, or install the new version from the download page.")
        }
        if path.hasPrefix("/Volumes/") {
            return gwL("ディスクイメージ（dmg）の中から起動しているため、入れ替えられません。\(appName) を「アプリケーション」フォルダへ移してからお使いください。",
                     "\(appName) is running from a disk image, so it can’t be replaced. Move it to the Applications folder first.")
        }
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().path
        let fm = FileManager.default
        if !fm.isWritableFile(atPath: parent) || !fm.isWritableFile(atPath: path) || !fm.isWritableFile(atPath: path + "/Contents") {
            return gwL("いまのアプリの置き場所（\(parent)）に書き込めないため、自動で入れ替えられません。配布ページから新しい版を入れてください。",
                     "The folder that contains \(appName) (\(parent)) isn’t writable, so it can’t be replaced automatically. Please install the new version from the download page.")
        }
        return nil
    }

    // MARK: - インストール

    private func install(_ m: Manifest) async {
        cancelled = false
        showProgress(gwL("ダウンロードしています…", "Downloading…"))
        do {
            guard let url = URL(string: m.url) else { throw UpdateError(gwL("台帳の URL が正しくありません。", "The update URL is invalid.")) }
            let work = try Self.prepareWorkDir()
            let dmg = try await download(url, to: work.appendingPathComponent("update.dmg"), expected: m.size)
            if cancelled { throw CancellationError() }
            setProgress(nil, gwL("確かめています…", "Verifying…"))
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            let team = try Self.ownTeamID()
            let current = currentVersion
            let appFolderName = Bundle.main.bundleURL.lastPathComponent
            let staged = try await Task.detached(priority: .userInitiated) {
                try Self.prepare(dmg: dmg, sha256: m.sha256, work: work, bundleID: bundleID, team: team,
                                 version: m.version, current: current, appFolderName: appFolderName)
            }.value
            if cancelled { throw CancellationError() }
            setProgress(nil, gwL("インストールの準備ができました。再起動します…", "Ready. Restarting…"))
            try launchHelper(staged: staged, work: work)
            hideProgress()
            log("\(m.version) を入れるために終了します")
            NSApp.terminate(nil)
            // terminate が取り消されたとき（終了の確認で「キャンセル」など）は、補助スクリプトが待ちくたびれて何もせず終わる。
        } catch is CancellationError {
            hideProgress()
        } catch {
            hideProgress()
            let msg = (error as? UpdateError)?.message ?? error.localizedDescription
            log("更新に失敗: \(msg)")
            let a = makeAlert(gwL("更新できませんでした", "The update couldn’t be installed"),
                              gwL("\(msg)\n\nいまの版はそのまま使えます。配布ページから新しい版を入れることもできます。",
                                "\(msg)\n\nYour current version is unchanged. You can also install the new version from the download page."))
            a.addButton(withTitle: gwL("閉じる", "Close"))
            if m.page != nil { a.addButton(withTitle: gwL("配布ページを開く", "Open Download Page")) }
            if run(a) == .alertSecondButtonReturn, let p = m.page, let u = URL(string: p) { NSWorkspace.shared.open(u) }
        }
    }

    nonisolated private static func prepareWorkDir() throws -> URL {
        let fm = FileManager.default
        let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "GigowatUpdater", isDirectory: true)
            .appendingPathComponent("GigowatUpdate", isDirectory: true)
        // 前回の残り（マウントしたままのものは無い前提）を消してから使う
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 自分の署名の Team ID。新しい版も同じ Team ID で署名されていなければ入れない。
    nonisolated private static func ownTeamID() throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty
        else {
            throw UpdateError(gwL("いまのアプリが Developer ID で署名されていないため、自動更新できません（開発用のビルドです）。",
                                "This copy isn’t signed with a Developer ID (it’s a development build), so it can’t update itself."))
        }
        return team
    }

    /// sha256 → dmg を開いて .app を写す → 署名・公証・版を確かめる。成功したら写した .app を返す。
    nonisolated private static func prepare(dmg: URL, sha256: String, work: URL, bundleID: String, team: String,
                                            version: String, current: String, appFolderName: String) throws -> URL {
        // 1. sha256
        let got = try fileSHA256(dmg)
        guard got.lowercased() == sha256.lowercased() else {
            throw UpdateError(gwL("ダウンロードしたファイルが台帳と一致しません（sha256 が違います）。", "The downloaded file doesn’t match the expected checksum."))
        }
        // 2. 読み取り専用で開き、.app を写す
        let mountRoot = work.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        let out = try runTool("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom", mountRoot.path, "-plist", dmg.path])
        guard let plist = try? PropertyListSerialization.propertyList(from: out, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw UpdateError(gwL("ディスクイメージを開けませんでした。", "Couldn’t open the disk image.")) }
        defer { _ = try? runTool("/usr/bin/hdiutil", ["detach", mount, "-force"]) }

        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(atPath: mount)) ?? []
        guard let appName = items.first(where: { name in
            name.hasSuffix(".app") && (Bundle(path: mount + "/" + name)?.bundleIdentifier == bundleID)
        }) else {
            throw UpdateError(gwL("ディスクイメージの中に、このアプリ（\(bundleID)）が見つかりません。", "The disk image doesn’t contain this app (\(bundleID))."))
        }
        let stagedDir = work.appendingPathComponent("new", isDirectory: true)
        try fm.createDirectory(at: stagedDir, withIntermediateDirectories: true)
        let staged = stagedDir.appendingPathComponent(appFolderName, isDirectory: true)
        _ = try runTool("/usr/bin/ditto", [mount + "/" + appName, staged.path])

        // 3. 署名: 同じ Team ID・同じバンドル ID・公証済み・中身が壊れていない
        var sc: SecStaticCode?
        guard SecStaticCodeCreateWithPath(staged as CFURL, [], &sc) == errSecSuccess, let sc else {
            throw UpdateError(gwL("新しい版の署名を読めませんでした。", "Couldn’t read the new version’s signature."))
        }
        let reqText = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\" and notarized"
        var req: SecRequirement?
        guard SecRequirementCreateWithString(reqText as CFString, [], &req) == errSecSuccess, let req else {
            throw UpdateError("SecRequirement")
        }
        var cfErr: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidityWithErrors(sc, flags, req, &cfErr)
        guard status == errSecSuccess else {
            let why = (cfErr?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String } ?? "OSStatus \(status)"
            throw UpdateError(gwL("新しい版の署名または公証を確かめられませんでした。上書きはしていません。\n（\(why)）",
                                "The new version’s signature or notarization couldn’t be verified, so nothing was replaced.\n(\(why))"))
        }
        // 4. 版と対応 OS
        guard let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist")),
              let newVersion = info["CFBundleShortVersionString"] as? String else {
            throw UpdateError(gwL("新しい版の情報を読めませんでした。", "Couldn’t read the new version’s information."))
        }
        guard compare(newVersion, version) == 0, compare(newVersion, current) > 0 else {
            throw UpdateError(gwL("ディスクイメージの中の版（\(newVersion)）が、台帳の版（\(version)）と合いません。", "The disk image contains version \(newVersion), not \(version)."))
        }
        if let minOS = info["LSMinimumSystemVersion"] as? String {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            if compare(minOS, "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)") > 0 {
                throw UpdateError(gwL("新しい版には macOS \(minOS) 以降が必要です。", "The new version requires macOS \(minOS) or later."))
            }
        }
        // ダウンロードしたものには隔離の印が付かないが、念のため外しておく
        _ = try? runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        try? fm.removeItem(at: dmg)
        return staged
    }

    nonisolated private static func fileSHA256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    nonisolated private static func runTool(_ path: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe(), errPipe = Pipe()
        p.standardOutput = pipe
        p.standardError = errPipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError("\((path as NSString).lastPathComponent) が失敗しました: \(String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return data
    }

    /// アプリの終了を待って差し替え、起動し直す補助スクリプトを動かす。
    private func launchHelper(staged: URL, work: URL) throws {
        let script = work.appendingPathComponent("install.sh")
        let text = """
        #!/bin/zsh
        # GigowatUpdater の補助: アプリの終了を待ってから差し替え、起動し直す。
        pid=$1; src=$2; dst=$3; work=$4
        log="$work/install.log"
        exec >>"$log" 2>&1
        echo "$(date '+%F %T') 開始 pid=$pid dst=$dst"
        for i in {1..1200}; do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
        if kill -0 $pid 2>/dev/null; then echo "アプリが終了しないので中止"; exit 1; fi
        old="$work/old.app"
        rm -rf "$old"
        if ! /bin/mv "$dst" "$old"; then
          echo "今の版を動かせない"; /usr/bin/open "$dst"; exit 1
        fi
        if ! /usr/bin/ditto "$src" "$dst"; then
          echo "新しい版を写せないので戻す"; rm -rf "$dst"; /bin/mv "$old" "$dst"; /usr/bin/open "$dst"; exit 1
        fi
        rm -rf "$old" "$src"
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dst" 2>/dev/null
        echo "$(date '+%F %T') 差し替え完了、起動"
        /usr/bin/open "$dst"
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), staged.path, Bundle.main.bundleURL.path, work.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    // MARK: - ダウンロード

    private func download(_ url: URL, to dest: URL, expected: Int?) async throws -> URL {
        let delegate = DownloadDelegate { [weak self] done, total in
            Task { @MainActor in
                let t = total > 0 ? total : Int64(expected ?? 0)
                self?.setProgress(t > 0 ? Double(done) / Double(t) : nil, nil)
            }
        }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            delegate.finish = { tmp, error in
                if let error { cont.resume(throwing: error); return }
                guard let tmp else { cont.resume(throwing: UpdateError(gwL("ダウンロードできませんでした。", "Download failed."))); return }
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    cont.resume(returning: dest)
                } catch { cont.resume(throwing: error) }
            }
            let task = session.downloadTask(with: url)
            self.downloadTask = task
            task.resume()
        }
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Int64, Int64) -> Void
        var finish: ((URL?, Error?) -> Void)?
        private var done = false
        init(progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten, totalBytesExpectedToWrite)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                complete(nil, UpdateError("HTTP \(http.statusCode)"))
                return
            }
            // location はこの呼び出しの間しか残らないので、すぐ移す
            let keep = location.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".dmg")
            do { try FileManager.default.moveItem(at: location, to: keep); complete(keep, nil) } catch { complete(nil, error) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { complete(nil, error) }
        }

        private func complete(_ url: URL?, _ error: Error?) {
            guard !done else { return }
            done = true
            finish?(url, error)
        }
    }

    // MARK: - 画面

    private func showProgress(_ text: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 110), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = gwL("\(appName) の更新", "Updating \(appName)")
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 20, y: 70, width: 340, height: 20)
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 46, width: 340, height: 16))
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        let cancel = NSButton(title: gwL("キャンセル", "Cancel"), target: self, action: #selector(cancelDownload))
        cancel.frame = NSRect(x: 270, y: 8, width: 96, height: 30)
        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(bar)
        panel.contentView?.addSubview(cancel)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        progressPanel = panel
        progressBar = bar
        progressLabel = label
    }

    private func setProgress(_ value: Double?, _ text: String?) {
        if let text { progressLabel?.stringValue = text }
        if let value {
            progressBar?.isIndeterminate = false
            progressBar?.doubleValue = value
        } else if text != nil {
            progressBar?.isIndeterminate = true
            progressBar?.startAnimation(nil)
        }
    }

    private func hideProgress() {
        progressPanel?.orderOut(nil)
        progressPanel = nil
    }

    @objc private func cancelDownload() {
        cancelled = true
        downloadTask?.cancel()
        hideProgress()
    }

    private func notesView(_ notes: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.string = notes
        tv.font = NSFont.systemFont(ofSize: 12)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        return scroll
    }

    private func makeAlert(_ title: String, _ text: String) -> NSAlert {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .informational
        return a
    }

    private func run(_ a: NSAlert) -> NSApplication.ModalResponse {
        // 試験用: 台帳を差し替えているときに限り、GigowatUpdaterTestAnswer（1〜3）でボタンを自動で選ぶ
        let d = UserDefaults.standard
        if d.string(forKey: manifestOverrideKey) != nil, d.integer(forKey: "GigowatUpdaterTestAnswer") > 0 {
            let n = d.integer(forKey: "GigowatUpdaterTestAnswer")
            log("試験の自動応答: 「\(a.messageText)」に \(n) 番目のボタン")
            return NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + n - 1)
        }
        NSApp.activate(ignoringOtherApps: true)
        a.window.level = .floating
        return a.runModal()
    }

    private func inform(_ title: String, _ text: String) {
        let a = makeAlert(title, text)
        a.addButton(withTitle: "OK")
        _ = run(a)
    }

    /// Console と ~/Library/Caches/<バンドルID>/GigowatUpdater.log の両方に残す
    private func log(_ s: String) {
        NSLog("GigowatUpdater: %@", s)
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let dir = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "GigowatUpdater", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("GigowatUpdater.log")
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(currentVersion) \(s)\n".utf8)
        if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: file) }
    }
}

private func gwL(_ ja: String, _ en: String) -> String {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("ja") ? ja : en
}
