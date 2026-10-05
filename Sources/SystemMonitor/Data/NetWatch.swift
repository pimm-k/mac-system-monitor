import Foundation
import Darwin
import Security
import UserNotifications

// MARK: - 設定

/// 怪しい通信の通知の設定 (アプリとバックグラウンド エージェントで共有)
enum NetAlertSettings {
    private enum Keys {
        static let enabled = "netAlertEnabled"
        static let upload = "netAlertUpload"
        static let ignored = "netAlertIgnored"
    }
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }
    /// 大量送信の通知
    static var upload: Bool {
        get { UserDefaults.standard.object(forKey: Keys.upload) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.upload) }
    }
    /// 「今後通知しない」にした "ルール|実行ファイルのパス"
    static var ignored: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Keys.ignored) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: Keys.ignored) }
    }
    static func ignoreKey(rule: String, path: String) -> String { "\(rule)|\(path)" }
}

// MARK: - 判定ルール

enum NetRule: String, CaseIterable {
    case port, location, signature, upload

    var title: String {
        switch self {
        case .port: return L("不審なポートへの通信")
        case .location: return L("一時フォルダ等のプログラムによる通信")
        case .signature: return L("署名のないプログラムによる通信")
        case .upload: return L("大量の送信が続いています")
        }
    }
    var icon: String {
        switch self {
        case .port: return "exclamationmark.shield"
        case .location: return "folder.badge.questionmark"
        case .signature: return "signature"
        case .upload: return "arrow.up.circle"
        }
    }
    var explanation: String {
        switch self {
        case .port: return L("マルウェアの遠隔操作・Tor・仮想通貨の採掘などでよく使われるポート番号への通信、またはそのポートでの待ち受け")
        case .location: return L("/tmp・ダウンロード・/Users/Shared など、普通のアプリが置かれない場所にあるプログラムの外部通信")
        case .signature: return L("コード署名が無い、または壊れている (改ざんの可能性がある) プログラムの外部通信")
        case .upload: return L("外部への送信が 1 分以上、平均 %@ MB/秒を超え続けた", "\(Int(NetWatch.uploadThreshold / 1_000_000))")
        }
    }
}

/// よく悪用されるポート番号と理由
enum SuspiciousPorts {
    static let table: [Int: String] = [
        4444: L("Metasploit などの遠隔操作ツールの既定ポート"),
        1337: L("バックドアでよく使われるポート"),
        31337: L("バックドアでよく使われるポート"),
        6666: L("IRC (ボットネットの指令サーバーでよく使われる)"),
        6667: L("IRC (ボットネットの指令サーバーでよく使われる)"),
        6668: L("IRC (ボットネットの指令サーバーでよく使われる)"),
        6669: L("IRC (ボットネットの指令サーバーでよく使われる)"),
        9001: L("Tor の中継ポート"),
        9030: L("Tor のディレクトリ ポート"),
        3333: L("仮想通貨マイニング プール (Stratum)"),
        14444: L("仮想通貨マイニング プール (Monero)"),
        45700: L("仮想通貨マイニング プール (Monero)"),
    ]
}

struct NetAlertRecord: Identifiable, Hashable {
    let id: Int64
    var ts: Int64
    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
    var rule: String
    var pid: Int32
    var name: String
    var path: String
    var remote: String
    var detail: String
    var ruleValue: NetRule? { NetRule(rawValue: rule) }
}

// MARK: - 接続の取得 (lsof)

struct NetConn: Hashable {
    var pid: pid_t
    var command: String
    var proto: String          // TCP / UDP
    var localHost: String
    var localPort: Int
    var remoteHost: String?    // 待ち受けのときは nil
    var remotePort: Int?
    var state: String          // ESTABLISHED / LISTEN / SYN_SENT など (UDP は空)

    var isListen: Bool { state == "LISTEN" }
    var remoteText: String {
        guard let h = remoteHost, let p = remotePort else { return L("待ち受け %@:%@", "\(localHost)", "\(localPort)") }
        return h.contains(":") ? "[\(h)]:\(p)" : "\(h):\(p)"
    }
}

enum NetConnections {
    /// このユーザーのプロセスのネットワーク接続一覧 (root なしで見える範囲)
    static func list() -> [NetConn] {
        let r = Shell.run("/usr/sbin/lsof", ["-nP", "-w", "-i", "-F", "pcfPnT"])
        guard !r.out.isEmpty else { return [] }
        var out: [NetConn] = []
        var pid: pid_t = 0, cmd = ""
        var proto = "", name = "", state = ""
        var inFile = false
        func flush() {
            defer { inFile = false; proto = ""; name = ""; state = "" }
            guard inFile, !name.isEmpty, let c = parse(pid: pid, cmd: cmd, proto: proto, name: name, state: state) else { return }
            out.append(c)
        }
        for line in r.out.split(separator: "\n") {
            guard let f = line.first else { continue }
            let v = String(line.dropFirst())
            switch f {
            case "p": flush(); pid = pid_t(v) ?? 0; cmd = ""
            case "c": cmd = v
            case "f": flush(); inFile = true
            case "P": proto = v
            case "n": name = v
            case "T": if v.hasPrefix("ST=") { state = String(v.dropFirst(3)) }
            default: break
            }
        }
        flush()
        return out
    }

    private static func parse(pid: pid_t, cmd: String, proto: String, name: String, state: String) -> NetConn? {
        let parts = name.components(separatedBy: "->")
        guard let local = splitHostPort(parts[0]) else { return nil }
        var c = NetConn(pid: pid, command: cmd, proto: proto, localHost: local.host, localPort: local.port,
                        remoteHost: nil, remotePort: nil, state: state)
        if parts.count > 1, let rem = splitHostPort(parts[1]) {
            c.remoteHost = rem.host
            c.remotePort = rem.port
        }
        return c
    }

    /// "1.2.3.4:443" / "[::1]:631" / "*:5000" を分解
    static func splitHostPort(_ s: String) -> (host: String, port: Int)? {
        guard let i = s.lastIndex(of: ":") else { return nil }
        var host = String(s[..<i])
        guard let port = Int(s[s.index(after: i)...]) else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }
        return (host, port)
    }

    /// ローカル・プライベート・マルチキャストのアドレスか
    static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "*" || h == "localhost" || h.isEmpty { return true }
        if h.contains(":") {   // IPv6
            if h == "::1" || h == "::" { return true }
            if h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("ff") { return true }
            if h.hasPrefix("::ffff:") { return isLocal(String(h.dropFirst(7))) }
            return false
        }
        let o = h.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4 else { return false }
        switch (o[0], o[1]) {
        case (10, _), (127, _), (0, _): return true
        case (172, 16...31), (192, 168), (169, 254), (100, 64...127): return true
        case (224...255, _): return true
        default: return false
        }
    }
}

// MARK: - コード署名の確認 (結果はキャッシュ)

enum CodeSignature {
    enum Status { case valid, unsigned, invalid }
    private static var cache: [String: (mtime: TimeInterval, status: Status)] = [:]
    private static let lock = NSLock()

    static func status(of path: String) -> Status {
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        lock.lock()
        if let c = cache[path], c.mtime == mtime { lock.unlock(); return c.status }
        lock.unlock()
        var s: Status = .valid
        var code: SecStaticCode?
        if SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code {
            // バンドル内のリソースまでは検証しない (重いため)。実行ファイル本体と署名は検証する
            let doNotValidateResources = SecCSFlags(rawValue: 1 << 2)
            let rc = SecStaticCodeCheckValidity(code, doNotValidateResources, nil)
            if rc == errSecCSUnsigned { s = .unsigned }
            else if rc != errSecSuccess { s = .invalid }
        }
        lock.lock()
        cache[path] = (mtime, s)
        if cache.count > 2000 { cache.removeAll() }
        lock.unlock()
        return s
    }
}

// MARK: - 監視本体

/// 記録エンジン (HistoryRecorder) から定期的に呼ばれ、怪しい通信を見つけたら記録・通知する
final class NetWatch {
    /// 確認の間隔 (秒)
    static let interval: Int64 = 15
    /// 同じ内容を再通知しない時間 (秒)
    static let cooldown: Int64 = 6 * 3600
    /// 大量送信とみなす送信速度 (バイト/秒) と継続時間 (秒)
    static let uploadThreshold: Double = 5_000_000
    static let uploadDuration: Int64 = 60
    static let uploadCooldown: Int64 = 1800

    private var lastCheck: Int64 = 0
    private var recent: [String: Int64] = [:]
    private var uploadSince: Int64? = nil
    private var lastUpload: Int64 = 0
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private var suspiciousDirs: [String] {
        ["/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/Users/Shared/", home + "/Downloads/"]
    }

    /// - Parameter txRate: 全体の送信速度 (バイト/秒)
    func check(now: Int64, txRate: Double, store: HistoryStore) {
        guard NetAlertSettings.enabled else { uploadSince = nil; return }
        checkUpload(now: now, txRate: txRate, store: store)
        guard now - lastCheck >= Self.interval else { return }
        lastCheck = now

        let ignored = NetAlertSettings.ignored
        var pathCache: [pid_t: String] = [:]
        for c in NetConnections.list() {
            let external = c.remoteHost.map { !NetConnections.isLocal($0) } ?? false
            let listeningOutside = c.isListen && !["127.0.0.1", "::1", "localhost"].contains(c.localHost)
            guard external || listeningOutside else { continue }

            let path = pathCache[c.pid] ?? ProcIdentity.path(c.pid)
            pathCache[c.pid] = path
            let name = path.isEmpty ? c.command : (path as NSString).lastPathComponent

            // 1. 不審なポート
            let port = c.isListen ? c.localPort : (c.remotePort ?? 0)
            if let why = SuspiciousPorts.table[port] {
                report(.port, conn: c, name: name, path: path, keyExtra: String(port),
                       detail: L("ポート %@: %@", "\(port)", "\(why)"), now: now, store: store, ignored: ignored)
            }
            guard !path.isEmpty else { continue }
            // 2. 置き場所
            if let dir = suspiciousDirs.first(where: { path.hasPrefix($0) }) {
                report(.location, conn: c, name: name, path: path, keyExtra: "",
                       detail: L("プログラムの場所: %@", "\(dir)"), now: now, store: store, ignored: ignored)
            }
            // 3. 署名
            switch CodeSignature.status(of: path) {
            case .valid: break
            case .unsigned:
                report(.signature, conn: c, name: name, path: path, keyExtra: "",
                       detail: L("コード署名がありません"), now: now, store: store, ignored: ignored)
            case .invalid:
                report(.signature, conn: c, name: name, path: path, keyExtra: "",
                       detail: L("コード署名が壊れています (改ざんの可能性)"), now: now, store: store, ignored: ignored)
            }
        }
    }

    private func checkUpload(now: Int64, txRate: Double, store: HistoryStore) {
        guard NetAlertSettings.upload, txRate >= Self.uploadThreshold else { uploadSince = nil; return }
        let since = uploadSince ?? now
        uploadSince = since
        guard now - since >= Self.uploadDuration, now - lastUpload >= Self.uploadCooldown else { return }
        lastUpload = now
        // ヒントとして、外部と多く接続しているプロセスを挙げる
        var counts: [String: Int] = [:]
        for c in NetConnections.list() where c.remoteHost.map({ !NetConnections.isLocal($0) }) ?? false {
            counts[c.command, default: 0] += 1
        }
        let top = counts.sorted { $0.value > $1.value }.prefix(3).map { L("%@ (%@ 接続)", "\($0.key)", "\($0.value)") }
        let detail = L("送信 %@ が %@ 秒以上続いています", "\(Fmt.rate(txRate))", "\(now - since)")
            + (top.isEmpty ? "" : L("\n外部との接続が多いプロセス: ") + top.joined(separator: ", "))
        store.insertNetAlert(ts: now, rule: NetRule.upload.rawValue, key: "upload", pid: 0,
                             name: L("システム全体"), path: "", remote: "", detail: detail)
        Notifier.post(title: "⚠️ " + NetRule.upload.title, body: detail, id: "upload-\(now)")
    }

    private func report(_ rule: NetRule, conn c: NetConn, name: String, path: String, keyExtra: String,
                        detail: String, now: Int64, store: HistoryStore, ignored: Set<String>) {
        if !path.isEmpty, ignored.contains(NetAlertSettings.ignoreKey(rule: rule.rawValue, path: path)) { return }
        let key = [rule.rawValue, path.isEmpty ? c.command : path, keyExtra, c.remoteHost ?? "listen"].joined(separator: "|")
        if let t = recent[key], now - t < Self.cooldown { return }
        if store.hasNetAlert(key: key, since: now - Self.cooldown) { recent[key] = now; return }
        recent[key] = now
        if recent.count > 5000 { recent = recent.filter { now - $0.value < Self.cooldown } }

        store.insertNetAlert(ts: now, rule: rule.rawValue, key: key, pid: c.pid, name: name, path: path,
                             remote: c.remoteText + " (\(c.proto))", detail: detail)
        Notifier.post(title: "⚠️ " + rule.title,
                      body: "\(name) (PID \(c.pid)) → \(c.remoteText)\n\(detail)",
                      id: key + "-\(now)")
    }
}

// MARK: - 通知センター

enum Notifier {
    static let openNetAlerts = Notification.Name("SystemMonitor.openNetAlerts")
    static let openUpdate = Notification.Name("SystemMonitor.openUpdate")

    /// .app として起動しているときだけ通知を使える (swift run では使えない)
    static var available: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// - Parameter kind: クリックされたときに開く画面 ("netAlert" / "update")
    static func post(title: String, body: String, id: String, kind: String = "netAlert") {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["kind": kind]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
