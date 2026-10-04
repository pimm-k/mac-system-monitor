import Foundation
import Darwin

/// 5 秒ごとにシステムとプロセスの状態を履歴データベースへ記録する。
/// アプリ本体とバックグラウンド エージェントの両方から使われるが、
/// ロックファイルを取得できた 1 つのプロセスだけが記録を担当する。
final class HistoryRecorder: @unchecked Sendable {
    static let interval: TimeInterval = 5
    static let cpuSpikeThreshold = 80.0      // CPU 使用率 (%)
    static let memSpikeThreshold = 90.0      // メモリ使用率 (%)
    static let spikeCooldown: Int64 = 120    // 同じ種類の高負荷記録の最短間隔 (秒)

    private struct ProcBrief { let name: String; let path: String; let user: String }
    private struct AppAcc { var path: String; var cpu: Double; var disk: Double; var mem: UInt64 }
    private struct MinuteAcc {
        var n = 0.0, cpu = 0.0, cpuMax = 0.0, mem = 0.0
        var diskR = 0.0, diskW = 0.0, netRx = 0.0, netTx = 0.0, gpu = 0.0
    }

    private var store: HistoryStore?
    private let sys = SystemSampler()
    private let netWatch = NetWatch()
    private let procs = ProcessSampler(psInterval: 30)   // 履歴は 10 分単位の集計なので ps は控えめに
    private var lockFD: Int32 = -1

    private var prevProcs: [pid_t: ProcBrief]? = nil
    private var prevCpuTime: [pid_t: (path: String, t: Double)] = [:]
    private var lastTick: Date? = nil
    private var minuteStart: Int64 = 0
    private var minute = MinuteAcc()
    private var apps: [String: AppAcc] = [:]
    private var lastFlush: Int64 = 0
    private var lastPrune: Int64 = 0
    private var lastSpike: [String: Int64] = [:]

    var isRecording: Bool { lockFD >= 0 }

    // MARK: ロック

    /// ロックを取得できたら記録担当になる (取得済みなら何もしない)
    @discardableResult
    func tryBecomeRecorder() -> Bool {
        if lockFD >= 0 { return true }
        HistoryPaths.ensureDirectory()
        let fd = Darwin.open(HistoryPaths.lock.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd
            if store == nil { store = HistoryStore() }
            return true
        }
        Darwin.close(fd)
        return false
    }

    /// 記録担当をやめる (バックグラウンド エージェントに任せるとき)
    func release() {
        guard lockFD >= 0 else { return }
        flushApps(now: Int64(Date().timeIntervalSince1970))
        flock(lockFD, LOCK_UN)
        Darwin.close(lockFD)
        lockFD = -1
        prevProcs = nil
        prevCpuTime = [:]
        lastTick = nil
    }

    // MARK: 記録

    func tick() {
        guard tryBecomeRecorder(), let store else { return }
        let nowDate = Date()
        let now = Int64(nowDate.timeIntervalSince1970)
        let dt = lastTick.map { max(0.5, nowDate.timeIntervalSince($0)) } ?? Self.interval
        lastTick = nowDate

        let s = sys.sample()
        let list = procs.sample(apps: [])
        let rx = s.nets.reduce(0) { $0 + $1.rx }
        let tx = s.nets.reduce(0) { $0 + $1.tx }
        let gpu = s.gpu?.utilization ?? 0

        store.db.exec("BEGIN")

        // 5 秒ごとのデータ
        store.insertSample(ts: now, cpu: s.cpu.total, mem: s.mem.percent, memUsed: s.mem.used,
                           diskR: s.disk.readRate, diskW: s.disk.writeRate,
                           netRx: rx, netTx: tx, gpu: gpu)

        // 1 分ごとのまとめ
        let minuteTs = now / 60 * 60
        if minuteStart != 0 && minuteTs != minuteStart && minute.n > 0 {
            let n = minute.n
            store.insertMinute(ts: minuteStart, cpu: minute.cpu / n, cpuMax: minute.cpuMax, mem: minute.mem / n,
                               diskR: minute.diskR / n, diskW: minute.diskW / n,
                               netRx: minute.netRx / n, netTx: minute.netTx / n, gpu: minute.gpu / n)
            minute = MinuteAcc()
        }
        minuteStart = minuteTs
        minute.n += 1
        minute.cpu += s.cpu.total
        minute.cpuMax = max(minute.cpuMax, s.cpu.total)
        minute.mem += s.mem.percent
        minute.diskR += s.disk.readRate
        minute.diskW += s.disk.writeRate
        minute.netRx += rx
        minute.netTx += tx
        minute.gpu += gpu

        // アプリ別の使用量
        var newCpu: [pid_t: (path: String, t: Double)] = [:]
        for p in list {
            newCpu[p.pid] = (p.path, p.cpuTime)
            var dCpu = 0.0
            if let prev = prevCpuTime[p.pid], prev.path == p.path, p.cpuTime >= prev.t {
                dCpu = p.cpuTime - prev.t
            }
            let disk = p.disk * dt
            guard dCpu > 0.001 || disk > 0 else { continue }
            let (name, path) = Self.appIdentity(p)
            var acc = apps[name] ?? AppAcc(path: path, cpu: 0, disk: 0, mem: 0)
            acc.cpu += dCpu
            acc.disk += disk
            acc.mem = max(acc.mem, p.memory)
            apps[name] = acc
        }
        prevCpuTime = newCpu

        // 起動・終了ログ
        var current: [pid_t: ProcBrief] = [:]
        for p in list { current[p.pid] = ProcBrief(name: p.name, path: p.path, user: p.user) }
        if let prev = prevProcs {
            for (pid, info) in current {
                if let old = prev[pid] {
                    if old.path == info.path { continue }
                    // 同じ PID が別のプロセスに再利用された
                    store.insertEvent(ts: now, started: false, pid: pid, name: old.name, path: old.path, user: old.user)
                }
                store.insertEvent(ts: now, started: true, pid: pid, name: info.name, path: info.path, user: info.user)
            }
            for (pid, info) in prev where current[pid] == nil {
                store.insertEvent(ts: now, started: false, pid: pid, name: info.name, path: info.path, user: info.user)
            }
        }
        prevProcs = current

        // 高負荷の記録
        if s.cpu.total >= Self.cpuSpikeThreshold, now - (lastSpike["cpu"] ?? 0) >= Self.spikeCooldown {
            let top = list.sorted { $0.cpu > $1.cpu }.prefix(5).map {
                "\($0.name) (PID \($0.pid))  CPU \(String(format: "%.1f", $0.cpu))%"
            }
            store.insertSpike(ts: now, kind: "cpu", value: s.cpu.total, top: top)
            lastSpike["cpu"] = now
        }
        if s.mem.percent >= Self.memSpikeThreshold, now - (lastSpike["mem"] ?? 0) >= Self.spikeCooldown {
            let top = list.sorted { $0.memory > $1.memory }.prefix(5).map {
                "\($0.name) (PID \($0.pid))  メモリ \(Fmt.bytes($0.memory))"
            }
            store.insertSpike(ts: now, kind: "mem", value: s.mem.percent, top: top)
            lastSpike["mem"] = now
        }

        // 1 分ごとにアプリ別使用量を書き出す
        if now - lastFlush >= 60 { flushApps(now: now) }

        store.db.exec("COMMIT")

        // 怪しい通信の確認 (15 秒ごと)
        netWatch.check(now: now, txRate: tx, store: store)

        // 1 時間ごとに古いデータを削除
        if now - lastPrune >= 3600 {
            store.prune(now: now)
            lastPrune = now
        }
    }

    private func flushApps(now: Int64) {
        guard let store, !apps.isEmpty else { lastFlush = now; return }
        let bucket = now / HistoryStore.appBucket * HistoryStore.appBucket
        for (name, a) in apps {
            store.addAppUsage(bucket: bucket, app: name, path: a.path, cpuSec: a.cpu, diskBytes: a.disk, memPeak: a.mem)
        }
        apps.removeAll()
        lastFlush = now
    }

    /// ヘルパー等は所属する .app にまとめる (例: Google Chrome Helper → Google Chrome)
    static func appIdentity(_ p: ProcItem) -> (name: String, path: String) {
        if let r = p.path.range(of: ".app/") {
            let bundle = String(p.path[..<r.lowerBound]) + ".app"
            let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            return (name, bundle)
        }
        return (p.name, p.path)
    }
}

// MARK: - バックグラウンド記録モード (画面なし)

enum HeadlessRecorder {
    static let flag = "--record"

    /// LaunchAgent から `SystemMonitor --record` で起動されたときの処理。終了しない。
    static func run() -> Never {
        setpriority(PRIO_PROCESS, 0, 10)   // 優先度を下げて他の作業の邪魔をしない
        let recorder = HistoryRecorder()
        while true {
            autoreleasepool {
                recorder.tick()
            }
            Thread.sleep(forTimeInterval: HistoryRecorder.interval)
        }
    }
}

// MARK: - LaunchAgent の管理

enum RecorderAgent {
    static let label = "local.pim.systemmonitor.recorder"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var domain: String { "gui/\(getuid())" }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    static var isInApplications: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    static var isRunning: Bool {
        let r = Shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"])
        return r.status == 0 && r.out.contains("state = running")
    }

    /// インストールして開始。失敗したらエラーメッセージを返す
    static func install() -> String? {
        guard let exe = Bundle.main.executablePath else { return "実行ファイルの場所を取得できませんでした。" }
        HistoryPaths.ensureDirectory()
        let log = HistoryPaths.directory.appendingPathComponent("recorder.log").path
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, HeadlessRecorder.flag],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return "設定ファイルを作成できませんでした: \(error.localizedDescription)"
        }
        Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let r = Shell.run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        if r.status != 0 {
            return "バックグラウンド記録を開始できませんでした: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return nil
    }

    /// 停止してアンインストール
    static func uninstall() -> String? {
        Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        if isInstalled {
            do { try FileManager.default.removeItem(at: plistURL) } catch {
                return "設定ファイルを削除できませんでした: \(error.localizedDescription)"
            }
        }
        return nil
    }
}
