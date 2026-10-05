import Foundation
import AppKit

// MARK: - 翻訳
//
// 画面に出す文字列は L("日本語の原文") で書く。
// 英語は Resources/en.lproj/Localizable.strings に「"日本語の原文" = "English";」の形で置く。
// 値を埋め込む所は %@ にして L("PID %@ は…", "\(pid)") のように渡す
// (この形のときは文中の % を %% と書く)。

/// 日本語で表示するか。
/// ja.lproj には翻訳表が無いため、日本語のときは原文 (キー) をそのまま使う
/// (macOS は表が見つからないと開発言語 = 英語の表を使ってしまうため)
private let showsJapanese: Bool =
    Bundle.main.preferredLocalizations.first?.hasPrefix("ja") ?? true

/// 日本語の原文をキーにして、今の言語の文字列を返す
func L(_ key: String, _ args: CVarArg...) -> String {
    let s = showsJapanese ? key : Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? s : String(format: s, arguments: args)
}

/// 同じ日本語でも英語を変えたい所用 (キーと日本語の原文を別にする)
func LK(_ key: String, _ japanese: String) -> String {
    showsJapanese ? japanese : Bundle.main.localizedString(forKey: key, value: japanese, table: nil)
}

// MARK: - 表示言語の設定

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ja, en
    var id: String { rawValue }

    /// 選択肢の表示名 (言語名はその言語のまま表示する)
    var title: String {
        switch self {
        case .system: return L("システムの設定に従う")
        case .ja: return "日本語"
        case .en: return "English"
        }
    }

    private static let key = "AppleLanguages"
    private static let choiceKey = "appLanguage"
    private static let chosenKey = "languageChosen"

    /// 今の設定 (未設定ならシステムの設定に従う)
    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: choiceKey) ?? "") ?? .system
    }

    /// 初回起動の言語選択を済ませたか
    static var hasChosen: Bool {
        get { UserDefaults.standard.bool(forKey: chosenKey) }
        set { UserDefaults.standard.set(newValue, forKey: chosenKey) }
    }

    /// 起動直後 (画面を出す前) に呼ぶ。
    /// 新しくインストールしたときだけ言語選択を出し、アップデート (以前から使っている) のときは出さない
    static func prepareFirstRun() {
        guard !hasChosen else { return }
        if isExistingInstall { hasChosen = true }
    }

    /// 以前にこのアプリを使ったことがあるか (設定や履歴データが残っているか)
    private static var isExistingInstall: Bool {
        let d = UserDefaults.standard
        // migratedFromTaskManager は新規インストールでも書かれるので判定に使わない
        let keys = ["lastTab", "lastPerformanceItem", "cpuGraphMode", "uiZoom", "uiAutoScale",
                    "updateLastCheck", "historySection", choiceKey]
        if keys.contains(where: { d.object(forKey: $0) != nil }) { return true }
        return FileManager.default.fileExists(atPath: HistoryPaths.database.path)
    }

    /// 設定を保存する (再起動はしない)
    private static func store(_ lang: AppLanguage) {
        let d = UserDefaults.standard
        d.set(lang.rawValue, forKey: choiceKey)
        switch lang {
        case .system: d.removeObject(forKey: key)
        case .ja, .en: d.set([lang.rawValue], forKey: key)
        }
        d.synchronize()
        // バックグラウンド記録 (通知の言語) も新しい設定で起動し直す
        if RecorderAgent.isInstalled {
            Shell.run("/bin/launchctl", ["kickstart", "-k", "\(RecorderAgent.domain)/\(RecorderAgent.label)"])
        }
    }

    /// 初回起動の言語選択の結果を反映する。今の表示と違えばすぐ再起動する
    @MainActor
    static func chooseOnFirstRun(_ lang: AppLanguage) {
        hasChosen = true
        guard lang != current else { return }
        let wasJapanese = Bundle.main.preferredLocalizations.first?.hasPrefix("ja") ?? true
        store(lang)
        let willBeJapanese: Bool = {
            switch lang {
            case .ja: return true
            case .en: return false
            case .system: return Locale.preferredLanguages.first?.hasPrefix("ja") ?? true
            }
        }()
        if wasJapanese != willBeJapanese { relaunch() }
    }

    /// 言語を変更する。反映には再起動が必要なので、確認して再起動する
    @MainActor
    static func set(_ lang: AppLanguage) {
        hasChosen = true
        guard lang != current else { return }
        store(lang)

        let alert = NSAlert()
        alert.messageText = L("表示言語を変更しました")
        alert.informativeText = L("新しい言語は再起動後に反映されます。今すぐ再起動しますか？")
        alert.addButton(withTitle: L("今すぐ再起動"))
        alert.addButton(withTitle: L("あとで"))
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { NSApp.terminate(nil); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
