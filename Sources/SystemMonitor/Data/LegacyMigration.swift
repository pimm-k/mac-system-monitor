import Foundation
import Darwin

/// v1.x「TaskManager」(local.pim.taskmanager) から v2「SystemMonitor」(local.pim.systemmonitor) への引き継ぎ。
/// 画面を開く前に 1 回だけ実行される。どの手順も、失敗してもアプリの起動は止めない。
enum LegacyMigration {
    static let oldBundleID = "local.pim.taskmanager"
    static let oldAgentLabel = "local.pim.taskmanager.recorder"
    private static let doneKey = "migratedFromTaskManager"

    /// 旧版で保存していた設定のキー
    private static let settingKeys = [
        "lastTab", "lastPerformanceItem", "cpuGraphMode", "uiZoom", "uiAutoScale", "cpuColumns",
        "historyRange", "historySection",
    ]

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let uid = getuid()

        // 1. 旧バックグラウンド記録を止める (新しいラベルで入れ直すため)
        let oldPlist = home.appendingPathComponent("Library/LaunchAgents/\(oldAgentLabel).plist")
        let hadAgent = fm.fileExists(atPath: oldPlist.path)
        if hadAgent {
            Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(oldAgentLabel)"])
            try? fm.removeItem(at: oldPlist)
        }

        // 2. 履歴データのフォルダを移す (新しい方がまだ無いときだけ)
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldDir = support.appendingPathComponent("TaskManager", isDirectory: true)
        let newDir = HistoryPaths.directory
        if fm.fileExists(atPath: oldDir.path) && !fm.fileExists(atPath: newDir.path) {
            try? fm.moveItem(at: oldDir, to: newDir)
            chmod(newDir.path, 0o700)
        }

        // 3. 設定 (前回のタブ・拡大率など) を引き継ぐ
        if let old = UserDefaults(suiteName: oldBundleID) {
            for key in settingKeys where defaults.object(forKey: key) == nil {
                if let v = old.object(forKey: key) { defaults.set(v, forKey: key) }
            }
        }

        // 4. 旧版でバックグラウンド記録を使っていたら、新しいアプリで再登録する
        if hadAgent {
            _ = RecorderAgent.install()
        }
    }
}
