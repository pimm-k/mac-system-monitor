import SwiftUI
import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // swift run で起動しても Dock に出て前面に来るように
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 怪しい通信の通知
        if Notifier.available {
            UNUserNotificationCenter.current().delegate = self
            if NetAlertSettings.enabled { Notifier.requestAuthorization() }
        }
    }

    /// アプリを前面に出しているときも通知を表示する
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// 通知をクリックしたら「履歴 → 通信の警告」を開く
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.userInfo["kind"] as? String == "netAlert" {
            UserDefaults.standard.set(HistorySection.network.rawValue, forKey: "historySection")
            UserDefaults.standard.set(Tab.history.rawValue, forKey: "lastTab")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: Notifier.openNetAlerts, object: nil)
            }
        }
        completionHandler()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// エントリーポイント。
/// `--record` 付きで起動されたら画面を出さずに履歴を記録し続ける (LaunchAgent 用)。
@main
enum Entry {
    @MainActor
    static func main() {
        // 言語が未設定なら日本語にする (文字列を読み込む前に行う)
        AppLanguage.applyDefaultIfNeeded()
        if CommandLine.arguments.contains(HeadlessRecorder.flag) {
            HeadlessRecorder.run()
        } else {
            // 旧名「TaskManager」からの設定・履歴・バックグラウンド記録の引き継ぎ (初回のみ)
            LegacyMigration.runIfNeeded()
            SystemMonitorApp.main()
        }
    }
}

struct SystemMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor = Monitor()
    @StateObject private var updater = Updater()

    var body: some Scene {
        Window(L("システムモニター"), id: "main") {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(updater)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L("アップデートを確認…")) { Task { await updater.check(userInitiated: true) } }
            }
            CommandGroup(after: .toolbar) {
                Button(L("拡大")) { monitor.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button(L("縮小")) { monitor.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button(L("実際のサイズ")) { monitor.zoomReset() }
                    .keyboardShortcut("0", modifiers: .command)
                Toggle(L("ウィンドウの大きさに合わせて拡大"), isOn: $monitor.autoScale)
                Divider()
            }
            CommandGroup(replacing: .newItem) {
                Button(L("新しいタスクを実行する…")) { monitor.runNewTask() }
                    .keyboardShortcut("n")
            }
        }
    }
}
