import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Tab: String, CaseIterable, Identifiable {
    case processes, performance, startup, users, details
    var id: String { rawValue }
    var title: String {
        switch self {
        case .processes: return "プロセス"
        case .performance: return "パフォーマンス"
        case .startup: return "スタートアップ アプリ"
        case .users: return "ユーザー"
        case .details: return "詳細"
        }
    }
    var icon: String {
        switch self {
        case .processes: return "square.grid.2x2"
        case .performance: return "waveform.path.ecg"
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
        case .fast: return "高速 (0.5 秒)"
        case .normal: return "標準 (1 秒)"
        case .slow: return "低速 (4 秒)"
        case .paused: return "一時停止"
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
    private var running = false

    var totalThreads: Int { processes.reduce(0) { $0 + $1.threads } }

    // MARK: - 更新ループ

    func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        while !Task.isCancelled {
            if speed != .paused { await tick() }
            try? await Task.sleep(nanoseconds: UInt64(speed.interval * 1_000_000_000))
        }
    }

    private func tick() async {
        let apps = NSWorkspace.shared.runningApplications.map {
            AppInfo(pid: $0.processIdentifier,
                    name: $0.localizedName ?? "",
                    bundleID: $0.bundleIdentifier,
                    bundlePath: $0.bundleURL?.path,
                    regular: $0.activationPolicy == .regular)
        }
        let ps = procSampler, ss = sysSampler
        let result = await Task.detached(priority: .utility) {
            (ps.sample(apps: apps), ss.sample())
        }.value
        apply(result.0, result.1)
    }

    private func apply(_ procs: [ProcItem], _ s: SystemSnapshot) {
        processes = procs
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
                alert = AlertInfo(title: "タスクを終了できませんでした", message: "対象のプロセスはすでに終了しています。")
            } else {
                alert = AlertInfo(
                    title: "アクセスが拒否されました",
                    message: "PID \(list) は別のユーザー (root など) のプロセスです。管理者として終了しますか？",
                    adminCommand: cmds.joined(separator: "; "))
            }
        } else if !replaced.isEmpty {
            alert = AlertInfo(
                title: "タスクを終了しませんでした",
                message: "PID \(replaced.map { String($0) }.joined(separator: " ")) は一覧の表示後に別のプロセスへ入れ替わったため、安全のため終了を中止しました。")
        } else if !errors.isEmpty {
            alert = AlertInfo(title: "タスクを終了できませんでした", message: errors.joined(separator: "\n"))
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
            alert = AlertInfo(title: "優先度を変更しませんでした",
                              message: "PID \(pid) は別のプロセスへ入れ替わったため、変更を中止しました。")
            return
        }
        if setpriority(PRIO_PROCESS, id_t(pid), nice) != 0 {
            guard let cmd = ProcIdentity.guarded(pid: pid, command: "/usr/bin/renice -n \(nice) -p \(pid)") else { return }
            alert = AlertInfo(
                title: "優先度を変更できません",
                message: "優先度を上げる、または他ユーザーのプロセスを変更するには管理者権限が必要です。",
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
                    self.alert = AlertInfo(title: "実行に失敗しました", message: r.err)
                }
            }
        }
    }

    func runNewTask() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "実行"
        panel.message = "実行するアプリを選んでください"
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
