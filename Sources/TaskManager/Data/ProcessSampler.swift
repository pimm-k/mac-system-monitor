import Foundation
import Darwin

/// メインスレッドで収集した NSRunningApplication の情報
struct AppInfo: Sendable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let bundlePath: String?
    let regular: Bool
}

/// 1 プロセス分の情報
struct ProcItem: Identifiable, Hashable, Sendable {
    let pid: pid_t
    var id: pid_t { pid }
    var ppid: pid_t
    var name: String
    var path: String
    var uid: uid_t
    var user: String
    var cpu: Double          // % (全コア合計を 100% とした値。Windows と同じ)
    var cpuTime: Double      // 累積 CPU 時間 (秒)
    var memory: UInt64       // バイト (取得できる場合は物理フットプリント)
    var threads: Int
    var diskRead: Double     // バイト/秒
    var diskWrite: Double
    var statusCode: Int32
    var nice: Int32
    var isRegularApp: Bool
    var bundleID: String?
    var bundlePath: String?
    var limited: Bool        // 他ユーザーのプロセスなどで詳細を取れない

    var disk: Double { diskRead + diskWrite }

    var status: String {
        switch statusCode {
        case 4: return "中断"
        case 5: return "ゾンビ"
        default: return ""
        }
    }

    var statusLong: String {
        switch statusCode {
        case 4: return "中断"
        case 5: return "ゾンビ"
        case 1: return "作成中"
        default: return "実行中"
        }
    }
}

/// libproc を使ってプロセス一覧を取得する
final class ProcessSampler: @unchecked Sendable {
    private struct Prev {
        let cpuNs: Double
        let diskR: UInt64
        let diskW: UInt64
        let t: UInt64
    }

    private var prev: [pid_t: Prev] = [:]
    private var users: [uid_t: String] = [:]

    // 軽量化: 実行ファイルのパスは PID ごとにキャッシュ (コマンド名が変わったら取り直す)
    private var pathCache: [pid_t: (comm: String, path: String)] = [:]

    // 軽量化: 他ユーザーのプロセス用の ps は毎回ではなく psInterval 秒ごとに実行する
    private let psInterval: Double
    private var psLast: [pid_t: (cpuNs: Double, rss: UInt64)] = [:]
    private var psLastTime: UInt64 = 0
    private var psCpu: [pid_t: Double] = [:]   // 直近 2 回の ps から求めた CPU 使用率

    /// - Parameter psInterval: 他ユーザー (root など) のプロセス情報を ps で取り直す間隔 (秒)
    init(psInterval: Double = 3) {
        self.psInterval = psInterval
    }
    private let ncpu = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
    private let timebase: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb.denom == 0 ? 1 : Double(tb.numer) / Double(tb.denom)
    }()

    func sample(apps: [AppInfo]) -> [ProcItem] {
        var appMap: [pid_t: AppInfo] = [:]
        for a in apps { appMap[a.pid] = a }

        let pids = listPids()
        let now = DispatchTime.now().uptimeNanoseconds
        var psChecked = false
        var newPrev: [pid_t: Prev] = [:]
        var items: [ProcItem] = []
        items.reserveCapacity(pids.count)

        for pid in pids {
            // 権限不要の短い BSD 情報
            var info = proc_bsdshortinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdshortinfo>.stride)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, infoSize) == infoSize else { continue }

            let comm = tupleString(info.pbsi_comm)
            let path: String
            if let c = pathCache[pid], c.comm == comm {
                path = c.path
            } else {
                path = processPath(pid)
                pathCache[pid] = (comm, path)
            }
            let app = appMap[pid]

            var name = app?.name ?? ""
            if name.isEmpty { name = path.isEmpty ? comm : (path as NSString).lastPathComponent }
            if name.isEmpty { name = pid == 0 ? "kernel_task" : "PID \(pid)" }

            var cpuNs = 0.0
            var memory: UInt64 = 0
            var threads = 0
            var diskR: UInt64 = 0, diskW: UInt64 = 0
            var limited = false

            // CPU 時間・スレッド (同一ユーザーのみ)
            var ti = proc_taskinfo()
            let tiSize = Int32(MemoryLayout<proc_taskinfo>.stride)
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, tiSize) == tiSize {
                cpuNs = Double(ti.pti_total_user + ti.pti_total_system) * timebase
                threads = Int(ti.pti_threadnum)
                memory = ti.pti_resident_size

                // 物理フットプリント・ディスク I/O
                var ru = rusage_info_v4()
                let r = withUnsafeMutablePointer(to: &ru) { ptr in
                    ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                    }
                }
                if r == 0 {
                    memory = ru.ri_phys_footprint
                    diskR = ru.ri_diskio_bytesread
                    diskW = ru.ri_diskio_byteswritten
                }
            } else {
                // 他ユーザー (root など) のプロセスは ps (setuid) から取得
                limited = true
                if !psChecked {
                    refreshPSIfNeeded(now: now)
                    psChecked = true
                }
                if let v = psLast[pid] {
                    cpuNs = v.cpuNs
                    memory = v.rss
                }
            }

            var cpu = 0.0, dr = 0.0, dw = 0.0
            if limited {
                cpu = psCpu[pid] ?? 0
            } else if let p = prev[pid], now > p.t {
                let dt = Double(now - p.t)
                if cpuNs >= p.cpuNs { cpu = (cpuNs - p.cpuNs) / dt * 100 / ncpu }
                if diskR >= p.diskR { dr = Double(diskR - p.diskR) / dt * 1e9 }
                if diskW >= p.diskW { dw = Double(diskW - p.diskW) / dt * 1e9 }
            }
            newPrev[pid] = Prev(cpuNs: cpuNs, diskR: diskR, diskW: diskW, t: now)

            errno = 0
            let nice = getpriority(PRIO_PROCESS, id_t(pid))

            items.append(ProcItem(
                pid: pid,
                ppid: pid_t(info.pbsi_ppid),
                name: name,
                path: path,
                uid: info.pbsi_uid,
                user: userName(info.pbsi_uid),
                cpu: min(cpu, 100),
                cpuTime: cpuNs / 1e9,
                memory: memory,
                threads: threads,
                diskRead: dr,
                diskWrite: dw,
                statusCode: Int32(info.pbsi_status),
                nice: nice,
                isRegularApp: app?.regular ?? false,
                bundleID: app?.bundleID,
                bundlePath: app?.bundlePath,
                limited: limited
            ))
        }
        prev = newPrev
        // 終了したプロセスのキャッシュを捨てる
        if pathCache.count > newPrev.count + 64 {
            pathCache = pathCache.filter { newPrev[$0.key] != nil }
        }
        return items
    }

    // MARK: - helpers

    private func listPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let n = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n))).filter { $0 >= 0 }
    }

    private func processPath(_ pid: pid_t) -> String {
        var buf = [UInt8](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard len > 0 else { return "" }
        return String(decoding: buf.prefix(Int(len)), as: UTF8.self)
    }

    private func userName(_ uid: uid_t) -> String {
        if let n = users[uid] { return n }
        var name = String(uid)
        if let pw = getpwuid(uid), let cname = pw.pointee.pw_name {
            name = String(cString: cname)
        }
        users[uid] = name
        return name
    }

    /// ps の結果が psInterval 秒より古ければ取り直し、前回との差から CPU 使用率を求める
    private func refreshPSIfNeeded(now: UInt64) {
        let elapsed = psLastTime == 0 ? Double.infinity : Double(now - psLastTime) / 1e9
        guard elapsed >= psInterval else { return }
        let snap = psSnapshot()
        var cpu: [pid_t: Double] = [:]
        if elapsed.isFinite, elapsed > 0 {
            for (pid, v) in snap {
                if let old = psLast[pid], v.cpuNs >= old.cpuNs {
                    cpu[pid] = min(100, (v.cpuNs - old.cpuNs) / (elapsed * 1e9) * 100 / ncpu)
                }
            }
        }
        psLast = snap
        psCpu = cpu
        psLastTime = now
    }

    private func psSnapshot() -> [pid_t: (cpuNs: Double, rss: UInt64)] {
        let r = Shell.run("/bin/ps", ["-axo", "pid=,time=,rss="])
        var map: [pid_t: (cpuNs: Double, rss: UInt64)] = [:]
        for line in r.out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = pid_t(parts[0]), let rss = UInt64(parts[2]) else { continue }
            map[pid] = (Self.parseTime(parts[1]) * 1e9, rss * 1024)
        }
        return map
    }

    /// "[dd-]hh:mm:ss.ss" / "mm:ss.ss" 形式を秒へ
    static func parseTime(_ s: Substring) -> Double {
        var str = s
        var days = 0.0
        if let dash = str.firstIndex(of: "-") {
            days = Double(str[..<dash]) ?? 0
            str = str[str.index(after: dash)...]
        }
        var total = 0.0
        for comp in str.split(separator: ":") {
            total = total * 60 + (Double(comp) ?? 0)
        }
        return total + days * 86400
    }
}
