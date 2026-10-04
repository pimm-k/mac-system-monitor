import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Tab: String, CaseIterable, Identifiable {
    case processes, performance, history, startup, users, details
    var id: String { rawValue }
    var title: String {
        switch self {
        case .processes: return L("プロセス")
        case .performance: return L("パフォーマンス")
        case .history: return L("履歴")
        case .startup: return L("スタートアップ アプリ")
        case .users: return LK("tab.users", "ユーザー")
        case .details: return L("詳細")
        }
    }
    var icon: String {
        switch self {
        case .processes: return "square.grid.2x2"
        case .performance: return "waveform.path.ecg"
        case .history: return "clock.arrow.circlepath"
        case .startup: return "speedometer"
        case .users: return "person.2"
        case .details: return "list.bullet"
        }
    }
}

enum UpdateSpeed: String, CaseIterable, Identifiable {
    case fast, normal, slow, paused
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: return L("高速 (0.5 秒)")
        case .normal: return L("標準 (1 秒)")
        case .slow: return L("低速 (4 秒)")
        case .paused: return L("一時停止")
        }
    }
    var interval: Double {
        switch self {
        case .fast: return 0.5
        case .normal: return 1
        case .slow: return 4
        case .paused: return 0.5
        }
    }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var adminCommand: String? = nil
}

/// 全データの取りまとめ役。UI から参照される。
@MainActor
final class Monitor: ObservableObject {
    nonisolated static let historyLength = 60

    @Published private(set) var processes: [ProcItem] = []
    @Published private(set) var system = SystemSnapshot()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var coreHistory: [[Double]] = []
    @Published private(set) var memHistory: [Double] = []
    @Published private(set) var diskActiveHistory: [Double] = []
    @Published private(set) var diskReadHistory: [Double] = []
    @Published private(set) var diskWriteHistory: [Double] = []
    @Published private(set) var netRxHistory: [String: [Double]] = [:]
    @Published private(set) var netTxHistory: [String: [Double]] = [:]
    @Published private(set) var gpuHistory: [Double] = []

    // MARK: 前回の表示状態 (次回起動時に復元する)
    private enum Keys {
        static let tab = "lastTab"
        static let perfItem = "lastPerformanceItem"
        static let cpuGraphMode = "cpuGraphMode"
        static let zoom = "uiZoom"
        static let autoScale = "uiAutoScale"
        static let cpuColumns = "cpuColumns"
    }

    /// 選択中のタブ
    @Published var tab: Tab? = Tab(rawValue: UserDefaults.standard.string(forKey: Keys.tab) ?? "") ?? .processes {
        didSet { UserDefaults.standard.set((tab ?? .processes).rawValue, forKey: Keys.tab) }
    }
    /// パフォーマンス タブで選択中の項目 (CPU / メモリ / ...)
    @Published var perfItem: PerfItem = PerfItem(key: UserDefaults.standard.string(forKey: Keys.perfItem) ?? "") {
        didSet { UserDefaults.standard.set(perfItem.key, forKey: Keys.perfItem) }
    }
    /// CPU グラフの表示モード (全体 / 論理プロセッサ)
    /// 手動の拡大率 (⌘+ / ⌘− / ⌘0)。1.0 = 標準
    @Published var zoom: Double = {
        let v = UserDefaults.standard.double(forKey: Keys.zoom)
        return v == 0 ? 1.0 : v
    }() {
        didSet { UserDefaults.standard.set(zoom, forKey: Keys.zoom) }
    }
    /// ウィンドウの大きさに合わせて自動で拡大するか
    @Published var autoScale: Bool = UserDefaults.standard.object(forKey: Keys.autoScale) as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoScale, forKey: Keys.autoScale) }
    }
    /// 論理プロセッサの列数 (0 = 自動)
    @Published var cpuColumns: Int = UserDefaults.standard.integer(forKey: Keys.cpuColumns) {
        didSet { UserDefaults.standard.set(cpuColumns, forKey: Keys.cpuColumns) }
    }

    /// 表示倍率 = ウィンドウ幅による自動倍率 × 手動の拡大率
    func uiScale(forWidth width: CGFloat) -> CGFloat {
        let auto: CGFloat = autoScale ? min(max(width / 1000, 1.0), 1.8) : 1.0
        return auto * CGFloat(zoom)
    }
    func zoomIn() { zoom = min(2.0, ((zoom + 0.1) * 10).rounded() / 10) }
    func zoomOut() { zoom = max(0.7, ((zoom - 0.1) * 10).rounded() / 10) }
    func zoomReset() { zoom = 1.0 }

    @Published var cpuGraphMode: CPUGraphMode = CPUGraphMode(rawValue: UserDefaults.standard.string(forKey: Keys.cpuGraphMode) ?? "") ?? .overall {
        didSet { UserDefaults.standard.set(cpuGraphMode.rawValue, forKey: Keys.cpuGraphMode) }
    }
    @Published var focusPid: pid_t? = nil
    @Published var speed: UpdateSpeed = .normal
    @Published var alert: AlertInfo? = nil
    @Published var alwaysOnTop = false {
        didSet {
            for w in NSApp.windows { w.level = alwaysOnTop ? .floating : .normal }
        }
    }

    let staticInfo = StaticInfo.load()
    private let procSampler = ProcessSampler()
    private let sysSampler = SystemSampler()
    /// バックグラウンド エージェントがないとき、アプリを開いている間だけ履歴を記録する
    private let recorder = HistoryRecorder()
    private var recorderTask: Task<Void, Never>?
    private var running = false

    var totalThreads: Int { processes.reduce(0) { $0 + $1.threads } }

    // MARK: - 更新ループ

    func run() async {
        guard !running else { return }
        running = true
        startRecorder()
        defer { running = false }
        var count = 0
        while !Task.isCancelled {
            let visible = isWindowVisible
            if speed != .paused {
                // 軽量化:
                //  - ウィンドウが見えていない (隠す・最小化・他のウィンドウの裏) ときはプロセス一覧を取らない
                //  - プロセス一覧を表示しないタブでは、プロセスは 5 回に 1 回だけ取る
                let needsProcesses = visible && (showsProcessList || count % 5 == 0 || processes.isEmpty)
                await tick(includeProcesses: needsProcesses)
                count += 1
            }
            // 見えていないときは更新間隔を 2 秒以上にする
            let interval = visible ? speed.interval : max(speed.interval, 2)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    /// 履歴の記録ループ (5 秒ごと)。エージェントが入っていればそちらに任せる
    private func startRecorder() {
        guard recorderTask == nil else { return }
        let rec = recorder
        recorderTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if RecorderAgent.isInstalled {
                    rec.release()
                } else {
                    rec.tick()
                }
                try? await Task.sleep(nanoseconds: UInt64(HistoryRecorder.interval * 1_000_000_000))
            }
        }
    }

    /// プロセス一覧を表示しているタブか
    private var showsProcessList: Bool {
        switch tab ?? .processes {
        case .processes, .users, .details: return true
        case .performance, .history, .startup: return false
        }
    }

    /// ウィンドウが画面に見えているか (隠す・最小化・完全に隠れているときは false)
    private var isWindowVisible: Bool {
        if NSApp.isHidden { return false }
        return NSApp.windows.contains { w in
            w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible) && w.canBecomeMain
        }
    }

    private func tick(includeProcesses: Bool) async {
        let ss = sysSampler
        guard includeProcesses else {
            let s = await Task.detached(priority: .utility) { ss.sample() }.value
            apply(nil, s)
            return
        }
        let apps = NSWorkspace.shared.runningApplications.map {
            AppInfo(pid: $0.processIdentifier,
                    name: $0.localizedName ?? "",
                    bundleID: $0.bundleIdentifier,
                    bundlePath: $0.bundleURL?.path,
                    regular: $0.activationPolicy == .regular)
        }
        let ps = procSampler
        let result = await Task.detached(priority: .utility) {
            (ps.sample(apps: apps), ss.sample())
        }.value
        apply(result.0, result.1)
    }

    private func apply(_ procs: [ProcItem]?, _ s: SystemSnapshot) {
        if let procs { processes = procs }
        system = s
        push(&cpuHistory, s.cpu.total)
        if coreHistory.count != s.cpu.perCore.count {
            coreHistory = Array(repeating: [], count: s.cpu.perCore.count)
        }
        for (i, v) in s.cpu.perCore.enumerated() { push(&coreHistory[i], v) }
        push(&memHistory, s.mem.percent)
        push(&diskActiveHistory, s.disk.active)
        push(&diskReadHistory, s.disk.readRate)
        push(&diskWriteHistory, s.disk.writeRate)
        for n in s.nets {
            push(&netRxHistory[n.id, default: []], n.rx)
            push(&netTxHistory[n.id, default: []], n.tx)
        }
        if let g = s.gpu { push(&gpuHistory, g.utilization) }
    }


    // MARK: - 操作

    /// タスクの終了。アプリは NSRunningApplication 経由で終了する。
    func endTask(pids: [pid_t], force: Bool, preferApp: Bool = true) {
        var denied: [pid_t] = []
        var errors: [String] = []
        var replaced: [pid_t] = []
        var expected: [pid_t: String] = [:]
        for p in processes { expected[p.pid] = p.path }
        for pid in pids where pid > 0 {
            // PID 再利用対策: 一覧に出ていたプロセスと同じか確認してから終了する
            guard ProcIdentity.matches(pid: pid, expectedPath: expected[pid]) else {
                replaced.append(pid)
                continue
            }
            if preferApp, let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                _ = force ? app.forceTerminate() : app.terminate()
                continue
            }
            if kill(pid, force ? SIGKILL : SIGTERM) != 0 {
                let e = errno
                if e == EPERM { denied.append(pid) } else { errors.append("PID \(pid): \(String(cString: strerror(e)))") }
            }
        }
        if !denied.isEmpty {
            let list = denied.map { String($0) }.joined(separator: " ")
            let sig = force ? 9 : 15
            // 承認されるまでに PID が入れ替わっても別プロセスを終了しないよう、実行直前に再確認する
            let cmds = denied.compactMap { ProcIdentity.guarded(pid: $0, command: "/bin/kill -\(sig) \($0)") }
            if cmds.isEmpty {
                alert = AlertInfo(title: L("タスクを終了できませんでした"), message: L("対象のプロセスはすでに終了しています。"))
            } else {
                alert = AlertInfo(
                    title: L("アクセスが拒否されました"),
                    message: L("PID %@ は別のユーザー (root など) のプロセスです。管理者として終了しますか？", "\(list)"),
                    adminCommand: cmds.joined(separator: "; "))
            }
        } else if !replaced.isEmpty {
            alert = AlertInfo(
                title: L("タスクを終了しませんでした"),
                message: L("PID %@ は一覧の表示後に別のプロセスへ入れ替わったため、安全のため終了を中止しました。", "\(replaced.map { String($0) }.joined(separator: " "))"))
        } else if !errors.isEmpty {
            alert = AlertInfo(title: L("タスクを終了できませんでした"), message: errors.joined(separator: "\n"))
        }
    }

    /// プロセスツリーの終了 (子 → 親の順で SIGKILL)
    func endTree(pid: pid_t) {
        var children: [pid_t: [pid_t]] = [:]
        for p in processes where p.pid != p.ppid { children[p.ppid, default: []].append(p.pid) }
        var order: [pid_t] = []
        var visited = Set<pid_t>()
        func visit(_ p: pid_t) {
            guard p > 1, visited.insert(p).inserted else { return }
            for c in children[p] ?? [] { visit(c) }
            order.append(p)
        }
        visit(pid)
        endTask(pids: order, force: true, preferApp: false)
    }

    func setPriority(pid: pid_t, nice: Int32) {
        let expected = processes.first(where: { $0.pid == pid })?.path
        guard ProcIdentity.matches(pid: pid, expectedPath: expected) else {
            alert = AlertInfo(title: L("優先度を変更しませんでした"),
                              message: L("PID %@ は別のプロセスへ入れ替わったため、変更を中止しました。", "\(pid)"))
            return
        }
        if setpriority(PRIO_PROCESS, id_t(pid), nice) != 0 {
            guard let cmd = ProcIdentity.guarded(pid: pid, command: "/usr/bin/renice -n \(nice) -p \(pid)") else { return }
            alert = AlertInfo(
                title: L("優先度を変更できません"),
                message: L("優先度を上げる、または他ユーザーのプロセスを変更するには管理者権限が必要です。"),
                adminCommand: cmd)
        }
    }

    func revealInFinder(path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        // .app 内の実行ファイルならアプリ本体を表示
        if let r = path.range(of: ".app/") {
            let appPath = String(path[..<r.lowerBound]) + ".app"
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appPath)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// osascript で管理者権限のコマンドを実行 (パスワードダイアログが表示される)
    func runAsAdmin(_ command: String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        Task.detached {
            let r = Shell.run("/usr/bin/osascript", ["-e", script])
            if r.status != 0 && !r.err.contains("-128") {
                await MainActor.run {
                    self.alert = AlertInfo(title: L("実行に失敗しました"), message: r.err)
                }
            }
        }
    }

    /// 「履歴 → 通信の警告」を開く (通知をクリックしたとき)
    func openNetworkAlerts() {
        UserDefaults.standard.set(HistorySection.network.rawValue, forKey: "historySection")
        NSApp.activate(ignoringOtherApps: true)
        if tab == .history {
            // 履歴タブを作り直して表示を切り替える
            tab = .processes
            DispatchQueue.main.async { self.tab = .history }
        } else {
            tab = .history
        }
    }

    func runNewTask() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L("実行")
        panel.message = L("実行するアプリを選んでください")
        if panel.runModal() == .OK, let url = panel.url {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }
}

/// 履歴配列に値を追加し、最大 60 件に保つ
private func push(_ a: inout [Double], _ v: Double) {
    a.append(v)
    if a.count > Monitor.historyLength { a.removeFirst(a.count - Monitor.historyLength) }
}
