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
            TaskManagerApp.main()
        }
    }
}

struct TaskManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        Window("タスク マネージャー", id: "main") {
            ContentView()
                .environmentObject(monitor)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新しいタスクを実行する…") { monitor.runNewTask() }
                    .keyboardShortcut("n")
            }
        }
    }
}
