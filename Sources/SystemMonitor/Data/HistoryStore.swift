import Foundation
import SQLite3

// MARK: - 保存場所

enum HistoryPaths {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SystemMonitor", isDirectory: true)
    }
    static var database: URL { directory.appendingPathComponent("history.sqlite") }
    static var lock: URL { directory.appendingPathComponent("recorder.lock") }

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }
}

// MARK: - 最小限の SQLite ラッパー

enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case null
}

final class SQLiteDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(path: String) {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 5000)
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    @discardableResult
    func run(_ sql: String, _ args: [SQLValue] = []) -> Bool {
        guard let st = prepare(sql, args) else { return false }
        defer { sqlite3_finalize(st) }
        let rc = sqlite3_step(st)
        return rc == SQLITE_DONE || rc == SQLITE_ROW
    }

    func query(_ sql: String, _ args: [SQLValue] = [], _ each: (SQLRow) -> Void) {
        guard let st = prepare(sql, args) else { return }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW { each(SQLRow(st: st)) }
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(st, idx, v)
            case .double(let v): sqlite3_bind_double(st, idx, v)
            case .text(let v): sqlite3_bind_text(st, idx, v, -1, Self.transient)
            case .null: sqlite3_bind_null(st, idx)
            }
        }
        return st
    }
}

struct SQLRow {
    let st: OpaquePointer
    func int(_ i: Int32) -> Int64 { sqlite3_column_int64(st, i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(st, i) }
    func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(st, i) else { return "" }
        return String(cString: c)
    }
    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(st, i) == SQLITE_NULL }
}

// MARK: - 画面用のモデル

struct HistoryPoint: Identifiable {
    let ts: Int64
    var id: Int64 { ts }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
    var cpu: Double
    var mem: Double
    var diskR: Double
    var diskW: Double
    var netRx: Double
    var netTx: Double
    var gpu: Double
    var segment: Int      // 記録が途切れた所で線を分けるための番号
}

struct AppHistoryRow: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var path: String
    var cpuSec: Double
    var diskBytes: Double
    var memPeak: UInt64
    var activeBuckets: Int   // 動いていた 10 分枠の数
    var activeMinutes: Int { activeBuckets * 10 }
}

struct ProcessEvent: Identifiable, Hashable {
    let id: Int64
    var ts: Int64
    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
    var started: Bool
    var pid: Int32
    var name: String
    var path: String
    var user: String
    var kindText: String { started ? L("起動") : L("終了") }
}

struct SpikeRecord: Identifiable, Hashable {
    let id: Int64
    var ts: Int64
    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
    var kind: String      // "cpu" / "mem"
    var value: Double
    var top: [String]
}

struct HistoryStats {
    var earliest: Date?
    var latest: Date?
    var fileSize: UInt64 = 0
}

// MARK: - 削除できるデータの種類

enum HistoryDataKind: String, CaseIterable, Identifiable, Sendable {
    case graphs, apps, spikes, network, events
    var id: String { rawValue }
    var title: String {
        switch self {
        case .graphs: return L("推移グラフ")
        case .apps: return L("アプリの履歴")
        case .spikes: return L("高負荷の記録")
        case .network: return L("通信の警告")
        case .events: return L("起動・終了ログ")
        }
    }
    var detail: String {
        switch self {
        case .graphs: return L("CPU・メモリ・ディスク・ネットワーク・GPU の推移")
        case .apps: return L("アプリごとの CPU 時間・ディスク量など")
        case .spikes: return L("CPU・メモリが高負荷になった時の上位プロセス")
        case .network: return L("怪しい通信の検知記録（通知しない設定は残ります）")
        case .events: return L("プロセスの起動・終了の記録")
        }
    }
    /// このデータを保存しているテーブル
    var tables: [String] {
        switch self {
        case .graphs: return ["samples", "samples_min"]
        case .apps: return ["app_usage"]
        case .spikes: return ["spikes"]
        case .network: return ["net_alerts"]
        case .events: return ["events"]
        }
    }
    /// 件数を数えるテーブル
    var countTable: String { self == .graphs ? "samples_min" : tables[0] }
}

// MARK: - 履歴データベース

final class HistoryStore: @unchecked Sendable {
    /// 5 秒ごとの細かいデータを残す期間
    static let rawRetention: Int64 = 24 * 3600
    /// 1 分ごと・アプリ別・ログを残す期間
    static let retention: Int64 = 30 * 86400
    /// アプリ別使用量の集計単位 (秒)
    static let appBucket: Int64 = 600

    let db: SQLiteDB

    init?() {
        HistoryPaths.ensureDirectory()
        let path = HistoryPaths.database.path
        guard let db = SQLiteDB(path: path) else { return nil }
        self.db = db
        createSchema()
        chmod(path, 0o600)   // 本人以外は読めないようにする
    }

    private func createSchema() {
        db.exec("PRAGMA auto_vacuum = INCREMENTAL")
        db.exec("PRAGMA journal_mode = WAL")
        db.exec("PRAGMA synchronous = NORMAL")
        db.exec("""
        CREATE TABLE IF NOT EXISTS samples(
            ts INTEGER PRIMARY KEY, cpu REAL, mem REAL, mem_used INTEGER,
            disk_r REAL, disk_w REAL, net_rx REAL, net_tx REAL, gpu REAL);
        CREATE TABLE IF NOT EXISTS samples_min(
            ts INTEGER PRIMARY KEY, cpu REAL, cpu_max REAL, mem REAL,
            disk_r REAL, disk_w REAL, net_rx REAL, net_tx REAL, gpu REAL);
        CREATE TABLE IF NOT EXISTS app_usage(
            bucket INTEGER, app TEXT, path TEXT, cpu_sec REAL, disk_bytes REAL, mem_peak INTEGER,
            PRIMARY KEY(bucket, app));
        CREATE TABLE IF NOT EXISTS events(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, started INTEGER,
            pid INTEGER, name TEXT, path TEXT, user TEXT);
        CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
        CREATE TABLE IF NOT EXISTS spikes(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, kind TEXT, value REAL, top TEXT);
        CREATE INDEX IF NOT EXISTS spikes_ts ON spikes(ts);
        CREATE TABLE IF NOT EXISTS net_alerts(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, rule TEXT, key TEXT,
            pid INTEGER, name TEXT, path TEXT, remote TEXT, detail TEXT);
        CREATE INDEX IF NOT EXISTS net_alerts_ts ON net_alerts(ts);
        CREATE INDEX IF NOT EXISTS net_alerts_key ON net_alerts(key, ts);
        """)
    }

    // MARK: 書き込み (記録エンジン用)

    func insertSample(ts: Int64, cpu: Double, mem: Double, memUsed: UInt64,
                      diskR: Double, diskW: Double, netRx: Double, netTx: Double, gpu: Double) {
        db.run("INSERT OR REPLACE INTO samples VALUES(?,?,?,?,?,?,?,?,?)",
               [.int(ts), .double(cpu), .double(mem), .int(Int64(memUsed)),
                .double(diskR), .double(diskW), .double(netRx), .double(netTx), .double(gpu)])
    }

    func insertMinute(ts: Int64, cpu: Double, cpuMax: Double, mem: Double,
                      diskR: Double, diskW: Double, netRx: Double, netTx: Double, gpu: Double) {
        db.run("INSERT OR REPLACE INTO samples_min VALUES(?,?,?,?,?,?,?,?,?)",
               [.int(ts), .double(cpu), .double(cpuMax), .double(mem),
                .double(diskR), .double(diskW), .double(netRx), .double(netTx), .double(gpu)])
    }

    func addAppUsage(bucket: Int64, app: String, path: String, cpuSec: Double, diskBytes: Double, memPeak: UInt64) {
        db.run("""
        INSERT INTO app_usage(bucket, app, path, cpu_sec, disk_bytes, mem_peak) VALUES(?,?,?,?,?,?)
        ON CONFLICT(bucket, app) DO UPDATE SET
            cpu_sec = cpu_sec + excluded.cpu_sec,
            disk_bytes = disk_bytes + excluded.disk_bytes,
            mem_peak = max(mem_peak, excluded.mem_peak),
            path = excluded.path
        """, [.int(bucket), .text(app), .text(path), .double(cpuSec), .double(diskBytes), .int(Int64(memPeak))])
    }

    func insertEvent(ts: Int64, started: Bool, pid: Int32, name: String, path: String, user: String) {
        db.run("INSERT INTO events(ts, started, pid, name, path, user) VALUES(?,?,?,?,?,?)",
               [.int(ts), .int(started ? 1 : 0), .int(Int64(pid)), .text(name), .text(path), .text(user)])
    }

    func insertSpike(ts: Int64, kind: String, value: Double, top: [String]) {
        db.run("INSERT INTO spikes(ts, kind, value, top) VALUES(?,?,?,?)",
               [.int(ts), .text(kind), .double(value), .text(top.joined(separator: "\n"))])
    }

    func insertNetAlert(ts: Int64, rule: String, key: String, pid: Int32, name: String,
                        path: String, remote: String, detail: String) {
        db.run("INSERT INTO net_alerts(ts, rule, key, pid, name, path, remote, detail) VALUES(?,?,?,?,?,?,?,?)",
               [.int(ts), .text(rule), .text(key), .int(Int64(pid)), .text(name), .text(path), .text(remote), .text(detail)])
    }

    func hasNetAlert(key: String, since: Int64) -> Bool {
        var found = false
        db.query("SELECT 1 FROM net_alerts WHERE key = ? AND ts >= ? LIMIT 1", [.text(key), .int(since)]) { _ in found = true }
        return found
    }

    /// 保存期間を過ぎたデータを削除
    func prune(now: Int64) {
        let rawLimit = now - Self.rawRetention
        let limit = now - Self.retention
        db.run("DELETE FROM samples WHERE ts < ?", [.int(rawLimit)])
        db.run("DELETE FROM samples_min WHERE ts < ?", [.int(limit)])
        db.run("DELETE FROM app_usage WHERE bucket < ?", [.int(limit)])
        db.run("DELETE FROM events WHERE ts < ?", [.int(limit)])
        db.run("DELETE FROM spikes WHERE ts < ?", [.int(limit)])
        db.run("DELETE FROM net_alerts WHERE ts < ?", [.int(limit)])
        db.exec("PRAGMA incremental_vacuum")
    }

    func deleteAll() {
        delete(Set(HistoryDataKind.allCases))
    }

    /// 選んだ種類のデータだけを削除する
    func delete(_ kinds: Set<HistoryDataKind>) {
        guard !kinds.isEmpty else { return }
        db.exec("BEGIN")
        // テーブル名は固定の一覧から選ぶ (外部からの文字列は使わない)
        for k in HistoryDataKind.allCases where kinds.contains(k) {
            for t in k.tables { db.exec("DELETE FROM \(t)") }
        }
        db.exec("COMMIT")
        if kinds.count == HistoryDataKind.allCases.count {
            db.exec("VACUUM")
        } else {
            db.exec("PRAGMA incremental_vacuum")
        }
    }

    /// 種類ごとの件数 (削除画面用)
    func counts() -> [HistoryDataKind: Int] {
        var out: [HistoryDataKind: Int] = [:]
        for k in HistoryDataKind.allCases {
            db.query("SELECT count(*) FROM \(k.countTable)") { r in out[k] = Int(r.int(0)) }
        }
        return out
    }

    // MARK: 読み出し (画面用)

    /// 期間内の推移。最大 maxPoints 点になるよう平均してまとめる
    func series(since: Int64, until: Int64, maxPoints: Int64 = 400) -> [HistoryPoint] {
        let span = max(until - since, 60)
        let useRaw = span <= Self.rawRetention
        let table = useRaw ? "samples" : "samples_min"
        let minStep: Int64 = useRaw ? 5 : 60
        let bucket = max(minStep, span / maxPoints)
        var points: [HistoryPoint] = []
        var segment = 0
        var prevTs: Int64? = nil
        db.query("""
        SELECT (ts / ?) * ? AS b, avg(cpu), avg(mem), avg(disk_r), avg(disk_w), avg(net_rx), avg(net_tx), avg(gpu)
        FROM \(table) WHERE ts >= ? AND ts <= ? GROUP BY b ORDER BY b
        """, [.int(bucket), .int(bucket), .int(since), .int(until)]) { r in
            let ts = r.int(0)
            if let p = prevTs, ts - p > bucket * 3 + minStep * 2 { segment += 1 }
            prevTs = ts
            points.append(HistoryPoint(ts: ts, cpu: r.double(1), mem: r.double(2),
                                       diskR: r.double(3), diskW: r.double(4),
                                       netRx: r.double(5), netTx: r.double(6),
                                       gpu: r.double(7), segment: segment))
        }
        return points
    }

    func appHistory(since: Int64) -> [AppHistoryRow] {
        var rows: [AppHistoryRow] = []
        db.query("""
        SELECT app, max(path), sum(cpu_sec), sum(disk_bytes), max(mem_peak), count(*)
        FROM app_usage WHERE bucket >= ? GROUP BY app ORDER BY 3 DESC LIMIT 500
        """, [.int(since - Self.appBucket)]) { r in
            rows.append(AppHistoryRow(name: r.text(0), path: r.text(1), cpuSec: r.double(2),
                                      diskBytes: r.double(3), memPeak: UInt64(max(0, r.int(4))),
                                      activeBuckets: Int(r.int(5))))
        }
        return rows
    }

    func events(since: Int64, limit: Int64 = 5000) -> [ProcessEvent] {
        var rows: [ProcessEvent] = []
        db.query("""
        SELECT id, ts, started, pid, name, path, user FROM events
        WHERE ts >= ? ORDER BY ts DESC, id DESC LIMIT ?
        """, [.int(since), .int(limit)]) { r in
            rows.append(ProcessEvent(id: r.int(0), ts: r.int(1), started: r.int(2) != 0,
                                     pid: Int32(truncatingIfNeeded: r.int(3)),
                                     name: r.text(4), path: r.text(5), user: r.text(6)))
        }
        return rows
    }

    func spikes(since: Int64, limit: Int64 = 1000) -> [SpikeRecord] {
        var rows: [SpikeRecord] = []
        db.query("SELECT id, ts, kind, value, top FROM spikes WHERE ts >= ? ORDER BY ts DESC LIMIT ?",
                 [.int(since), .int(limit)]) { r in
            let top = r.text(4).split(separator: "\n").map(String.init)
            rows.append(SpikeRecord(id: r.int(0), ts: r.int(1), kind: r.text(2), value: r.double(3), top: top))
        }
        return rows
    }

    func netAlerts(since: Int64, limit: Int64 = 1000) -> [NetAlertRecord] {
        var rows: [NetAlertRecord] = []
        db.query("""
        SELECT id, ts, rule, pid, name, path, remote, detail FROM net_alerts
        WHERE ts >= ? ORDER BY ts DESC, id DESC LIMIT ?
        """, [.int(since), .int(limit)]) { r in
            rows.append(NetAlertRecord(id: r.int(0), ts: r.int(1), rule: r.text(2),
                                       pid: Int32(truncatingIfNeeded: r.int(3)), name: r.text(4),
                                       path: r.text(5), remote: r.text(6), detail: r.text(7)))
        }
        return rows
    }

    func stats() -> HistoryStats {
        var s = HistoryStats()
        db.query("SELECT min(ts), max(ts) FROM samples_min") { r in
            if !r.isNull(0) { s.earliest = Date(timeIntervalSince1970: TimeInterval(r.int(0))) }
        }
        db.query("SELECT min(ts), max(ts) FROM samples") { r in
            if !r.isNull(0) {
                let e = Date(timeIntervalSince1970: TimeInterval(r.int(0)))
                if s.earliest == nil || e < s.earliest! { s.earliest = e }
                s.latest = Date(timeIntervalSince1970: TimeInterval(r.int(1)))
            }
        }
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let p = HistoryPaths.database.path + suffix
            if let size = (try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber {
                s.fileSize += size.uint64Value
            }
        }
        return s
    }
}
