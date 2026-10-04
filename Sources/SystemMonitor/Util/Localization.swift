import Foundation
import AppKit

// MARK: - 翻訳
//
// 画面に出す文字列は L("日本語の原文") で書く。
// 英語は Resources/en.lproj/Localizable.strings に「"日本語の原文" = "English";」の形で置く。
// 値を埋め込む所は %@ にして L("PID %@ は…", "\(pid)") のように渡す
// (この形のときは文中の % を %% と書く)。

/// 日本語の原文をキーにして、今の言語の文字列を返す
func L(_ key: String, _ args: CVarArg...) -> String {
    let s = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? s : String(format: s, arguments: args)
}

/// 同じ日本語でも英語を変えたい所用 (キーと日本語の原文を別にする)
func LK(_ key: String, _ japanese: String) -> String {
    Bundle.main.localizedString(forKey: key, value: japanese, table: nil)
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

    /// 今の設定
    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: choiceKey) ?? "") ?? .system
    }

    /// 言語を変更する。反映には再起動が必要なので、確認して再起動する
    @MainActor
    static func set(_ lang: AppLanguage) {
        guard lang != current else { return }
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
