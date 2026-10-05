import Foundation
import AppKit
import CryptoKit

/// GitHub Releases から新しいバージョンを確認し、アプリ内で更新する。
///
/// 安全のため次を確認してから置き換える:
/// - 通信は HTTPS、ダウンロード元は github.com / *.githubusercontent.com のみ
/// - Release に添付された .sha256 とダウンロードした zip のハッシュが一致すること
/// - 展開したアプリのバンドル ID が同じで、バージョンがタグと一致すること
/// - `codesign --verify --deep --strict` が通ること (改ざんされていないこと)
@MainActor
final class Updater: ObservableObject {
    nonisolated static let repo = "pimm-k/mac-system-monitor"
    nonisolated private static let bundleID = "local.pim.systemmonitor"
    private enum Keys {
        static let autoCheck = "updateAutoCheck"
        static let lastCheck = "updateLastCheck"
        static let skipped = "updateSkippedVersion"
    }

    struct Release: Equatable {
        let version: String
        let notes: String
        let pageURL: URL
        let zipURL: URL
        let shaURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release)
        case installing
        case failed(String)
    }

    @Published var state: State = .idle
    /// アップデートのお知らせシートを出すか
    @Published var showSheet = false
    @Published var autoCheck: Bool = UserDefaults.standard.object(forKey: Keys.autoCheck) as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: Keys.autoCheck) }
    }

    var current: String { AppVersion.short ?? "0.0.0" }

    /// 自動確認の間隔 (アプリを開いている間も、この間隔で確認する)
    static let autoCheckInterval: TimeInterval = 3600

    /// 自動確認のループ。起動時に 1 回、その後はアプリを開いている間 1 時間ごとに確認する。
    /// 起動時に見つかったらお知らせ画面を出し、開いている間に見つかったときは
    /// 画面を邪魔しないようツールバーとサイドバーのボタンだけで知らせる
    func runAutoCheck() async {
        var firstRun = true
        while !Task.isCancelled {
            if autoCheck, AppVersion.short != nil {
                let last = UserDefaults.standard.double(forKey: Keys.lastCheck)
                if Date().timeIntervalSince1970 - last >= Self.autoCheckInterval - 60 {
                    await check(userInitiated: false, presentSheet: firstRun)
                }
            }
            firstRun = false
            try? await Task.sleep(nanoseconds: UInt64(Self.autoCheckInterval * 1_000_000_000))
        }
    }

    /// 新しいバージョンがあるか
    var availableRelease: Release? {
        switch state {
        case .available(let r), .downloading(let r): return r
        default: return nil
        }
    }

    /// 新しいバージョンがあるか確認する
    func check(userInitiated: Bool, presentSheet: Bool = true) async {
        if case .downloading = state { return }
        if state == .installing { return }
        // 自動確認で見つかって表示中のものは、確認中の表示に戻さない
        if userInitiated || availableRelease == nil { state = .checking }
        if userInitiated { showSheet = true }
        do {
            let rel = try await Self.fetchLatest()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.lastCheck)
            if Self.isNewer(rel.version, than: current) {
                state = .available(rel)
                let skipped = UserDefaults.standard.string(forKey: Keys.skipped)
                if userInitiated || (presentSheet && skipped != rel.version) { showSheet = true }
                // 自動確認で見つけたときは通知センターにも知らせる (同じバージョンは 1 回だけ)
                if !userInitiated { UpdateNotifier.notifyIfNeeded(version: rel.version) }
            } else {
                state = .upToDate
            }
        } catch {
            if userInitiated { state = .failed(error.localizedDescription) }
            else if availableRelease == nil { state = .idle }
        }
    }

    func skip(_ rel: Release) {
        UserDefaults.standard.set(rel.version, forKey: Keys.skipped)
        showSheet = false
        state = .idle
    }

    /// ダウンロード → 検証 → 置き換え → 再起動
    func install(_ rel: Release) {
        let appURL = Bundle.main.bundleURL
        guard AppVersion.short != nil, appURL.pathExtension == "app" else {
            state = .failed(L("swift run で起動したときは更新できません。"))
            return
        }
        let parent = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            state = .failed(L("%@ に書き込めないため更新できません。Releases ページから手動で入れ替えてください。", "\(parent.path)"))
            return
        }
        if appURL.path.contains("/AppTranslocation/") || appURL.path.hasPrefix("/Volumes/") {
            state = .failed(L("ディスクイメージや一時的な場所から起動しているため更新できません。アプリを「アプリケーション」フォルダに入れてから起動してください。"))
            return
        }
        state = .downloading(rel)
        Task.detached(priority: .userInitiated) {
            do {
                let newApp = try await Self.downloadAndVerify(rel)
                await MainActor.run { self.state = .installing }
                try Self.replaceAndRelaunch(current: appURL, with: newApp)
                await MainActor.run { NSApp.terminate(nil) }
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: - GitHub API

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ m: String) { message = m }
    }

    /// キャッシュを使わない通信 (アップデート確認用)
    nonisolated private static let noCacheSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: c)
    }()

    nonisolated static func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SystemMonitor-Updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        // GitHub API の応答は 60 秒キャッシュされるため、毎回サーバーに問い合わせる
        // (キャッシュされた古い「最新版」の情報で「最新です」と判定されないように)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, resp) = try await Self.noCacheSession.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError(L("GitHub から最新版の情報を取得できませんでした。"))
        }
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct R: Decodable { let tag_name: String; let body: String?; let html_url: String; let assets: [Asset]; let draft: Bool; let prerelease: Bool }
        let r = try JSONDecoder().decode(R.self, from: data)
        guard !r.draft, !r.prerelease else { throw UpdateError(L("正式版のリリースが見つかりません。")) }
        let tag = r.tag_name
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
            throw UpdateError(L("リリースのバージョン表記 (%@) を読み取れません。", "\(tag)"))
        }
        let zipName = "SystemMonitor-\(tag).zip"
        guard let zip = r.assets.first(where: { $0.name == zipName }).flatMap({ URL(string: $0.browser_download_url) }),
              let sha = r.assets.first(where: { $0.name == zipName + ".sha256" }).flatMap({ URL(string: $0.browser_download_url) }),
              let page = URL(string: r.html_url),
              isTrusted(zip), isTrusted(sha)
        else { throw UpdateError(L("リリースに必要なファイル (%@ と .sha256) が見つかりません。", "\(zipName)")) }
        return Release(version: version, notes: r.body ?? "", pageURL: page, zipURL: zip, shaURL: sha)
    }

    /// ダウンロードを許可するホスト
    nonisolated static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    /// "2.10.0" > "2.9.1" のような数値比較
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - ダウンロードと検証

    /// リダイレクト先も信頼できるホストに限定する
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let u = request.url, Updater.isTrusted(u) else { return nil }
            return request
        }
    }

    nonisolated private static func download(_ url: URL, to dest: URL) async throws {
        let (tmp, resp) = try await URLSession.shared.download(from: url, delegate: RedirectGuard())
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError(L("ダウンロードに失敗しました: %@", "\(url.lastPathComponent)"))
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    nonisolated private static func downloadAndVerify(_ rel: Release) async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("SystemMonitor-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let zip = work.appendingPathComponent("update.zip")
        let sha = work.appendingPathComponent("update.zip.sha256")
        try await download(rel.zipURL, to: zip)
        try await download(rel.shaURL, to: sha)

        // 1. ハッシュ
        let expected = (try String(contentsOf: sha, encoding: .utf8))
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first.map(String.init)?.lowercased() ?? ""
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard expected.count == 64, expected == actual else {
            throw UpdateError(L("ダウンロードしたファイルのハッシュが一致しません。更新を中止しました。"))
        }

        // 2. 展開
        let out = work.appendingPathComponent("unzipped")
        let r = Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        guard r.status == 0 else { throw UpdateError(L("展開に失敗しました: %@", "\(r.err)")) }
        let app = out.appendingPathComponent("SystemMonitor.app")
        guard fm.fileExists(atPath: app.path), let info = Bundle(url: app)?.infoDictionary else {
            throw UpdateError(L("更新ファイルの中にアプリが見つかりません。"))
        }

        // 3. 中身の確認
        guard info["CFBundleIdentifier"] as? String == bundleID else {
            throw UpdateError(L("更新ファイルのアプリが別物です (バンドル ID 不一致)。更新を中止しました。"))
        }
        guard info["CFBundleShortVersionString"] as? String == rel.version else {
            throw UpdateError(L("更新ファイルのバージョンがリリースと一致しません。更新を中止しました。"))
        }

        // 4. 署名 (改ざんされていないか)
        let cs = Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard cs.status == 0 else {
            throw UpdateError(L("アプリの署名を確認できません。更新を中止しました。\n%@", "\(cs.err)"))
        }
        // ダウンロード由来の隔離属性が付いていれば外す (中身は上で検証済み)
        Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    /// 終了を待ってから入れ替えて起動し直す小さなスクリプトを実行する
    nonisolated private static func replaceAndRelaunch(current: URL, with newApp: URL) throws {
        let pid = getpid()
        let uid = getuid()
        let backup = current.path + ".old"
        let script = """
        #!/bin/bash
        # システムモニターのアップデート (自動生成)
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        CUR=\(Shell.quote(current.path))
        NEW=\(Shell.quote(newApp.path))
        BAK=\(Shell.quote(backup))
        AGENT_PLIST="$HOME/Library/LaunchAgents/\(RecorderAgent.label).plist"
        # 入れ替え中に launchd がバックグラウンド記録を再起動しないよう、先に止める
        # (途中の状態で起動すると署名エラーで強制終了されるため)
        if [ -f "$AGENT_PLIST" ]; then
          /bin/launchctl bootout gui/\(uid)/\(RecorderAgent.label) >/dev/null 2>&1 || true
        fi
        rm -rf "$BAK"
        if mv "$CUR" "$BAK"; then
          if /usr/bin/ditto "$NEW" "$CUR"; then
            rm -rf "$BAK"
          else
            rm -rf "$CUR"; mv "$BAK" "$CUR"   # 失敗したら元に戻す
          fi
        fi
        if [ -f "$AGENT_PLIST" ]; then
          /bin/launchctl bootstrap gui/\(uid) "$AGENT_PLIST" >/dev/null 2>&1 \\
            || /bin/launchctl kickstart -k gui/\(uid)/\(RecorderAgent.label) >/dev/null 2>&1 || true
        fi
        /usr/bin/open "$CUR"
        rm -rf \(Shell.quote(newApp.deletingLastPathComponent().deletingLastPathComponent().path))
        """
        let url = newApp.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("install.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}

// MARK: - アップデートの通知

/// 新しいバージョンを通知センターで知らせる。
/// アプリを開いている間はアプリが、閉じている間はバックグラウンド記録のエージェントが確認する。
enum UpdateNotifier {
    private static let autoCheckKey = "updateAutoCheck"
    private static let skippedKey = "updateSkippedVersion"
    private static let notifiedKey = "updateNotifiedVersion"
    private static let agentLastCheckKey = "updateAgentLastCheck"
    /// エージェントが確認する間隔 (秒)
    static let agentInterval: TimeInterval = 6 * 3600

    /// 「自動で確認して通知する」がオンか (アプリの設定と共通)
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true
    }

    /// まだ通知していないバージョンなら通知する
    static func notifyIfNeeded(version: String) {
        let d = UserDefaults.standard
        guard enabled, d.string(forKey: notifiedKey) != version, d.string(forKey: skippedKey) != version else { return }
        d.set(version, forKey: notifiedKey)
        Notifier.post(title: L("アップデートがあります"),
                      body: L("システムモニター v%@ が利用できます。クリックするとアップデート画面を開きます。", version),
                      id: "update-\(version)", kind: "update")
    }

    /// バックグラウンド エージェントから定期的に呼ぶ (6 時間ごとに確認。通信は別スレッドで行う)
    static func backgroundCheckIfDue() {
        let d = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        guard enabled, let current = AppVersion.short,
              now - d.double(forKey: agentLastCheckKey) >= agentInterval else { return }
        d.set(now, forKey: agentLastCheckKey)
        Task.detached(priority: .background) {
            guard let rel = try? await Updater.fetchLatest(),
                  Updater.isNewer(rel.version, than: current) else { return }
            notifyIfNeeded(version: rel.version)
        }
    }
}

