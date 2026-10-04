import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // swift run で起動しても Dock に出て前面に来るように
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// エントリーポイント。
/// `--record` 付きで起動されたら画面を出さずに履歴を記録し続ける (LaunchAgent 用)。
@main
enum Entry {
    @MainActor
    static func main() {
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

    var body: some Scene {
        Window("システムモニター", id: "main") {
            ContentView()
                .environmentObject(monitor)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("拡大") { monitor.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("縮小") { monitor.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("実際のサイズ") { monitor.zoomReset() }
                    .keyboardShortcut("0", modifiers: .command)
                Toggle("ウィンドウの大きさに合わせて拡大", isOn: $monitor.autoScale)
                Divider()
            }
            CommandGroup(replacing: .newItem) {
                Button("新しいタスクを実行する…") { monitor.runNewTask() }
                    .keyboardShortcut("n")
            }
        }
    }
}
