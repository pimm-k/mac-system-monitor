import Foundation
import Darwin

/// LaunchAgents / LaunchDaemons の項目
struct LaunchItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case userAgent, globalAgent, daemon

        var title: String {
            switch self {
            case .userAgent: return L("ユーザー エージェント")
            case .globalAgent: return L("グローバル エージェント")
            case .daemon: return L("システム デーモン")
            }
        }
    }

    var id: String { path }
    let label: String
    let path: String
    let program: String
    let kind: Kind
    let runAtLoad: Bool
    let keepAlive: Bool
    var disabled: Bool
    var running: Bool?

    var kindName: String { kind.title }
    var statusText: String { disabled ? L("無効") : L("有効") }
    var runningText: String {
        switch running {
        case .some(true): return L("実行中")
        case .some(false): return L("停止")
        case .none: return "—"
        }
    }
    var runAtLoadText: String { runAtLoad || keepAlive ? L("はい") : L("いいえ") }

    /// com.google.keystone → Google
    var publisher: String {
        let parts = label.split(separator: ".")
        let tlds: Set<String> = ["com", "org", "net", "io", "jp", "co", "de", "us", "uk", "app", "dev"]
        if parts.count >= 2, tlds.contains(parts[0].lowercased()) {
            return parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        }
        return parts.first.map(String.init) ?? ""
    }
}

enum LaunchItemLoader {
    static func load(runningPaths: Set<String>) -> [LaunchItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs: [(String, LaunchItem.Kind)] = [
            ("\(home)/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .globalAgent),
            ("/Library/LaunchDaemons", .daemon),
        ]
        let uid = getuid()
        let guiDisabled = disabledMap(domain: "gui/\(uid)")
        let sysDisabled = disabledMap(domain: "system")
        let loaded = launchctlList()

        var items: [LaunchItem] = []
        for (dir, kind) in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".plist") {
                let path = dir + "/" + file
                guard let data = FileManager.default.contents(atPath: path),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
                else { continue }

                let label = plist["Label"] as? String ?? String(file.dropLast(6))
                let program = plist["Program"] as? String
                    ?? (plist["ProgramArguments"] as? [String])?.first ?? ""
                let runAtLoad = plist["RunAtLoad"] as? Bool ?? false
                let keepAlive = (plist["KeepAlive"] as? Bool) ?? (plist["KeepAlive"] is [String: Any])
                let plistDisabled = plist["Disabled"] as? Bool ?? false
                let override = (kind == .daemon ? sysDisabled : guiDisabled)[label]

                var running: Bool? = nil
                if kind != .daemon, let pid = loaded[label] {
                    running = pid != nil
                } else if !program.isEmpty {
                    running = runningPaths.contains(program) ? true : (kind == .daemon ? nil : false)
                }

                items.append(LaunchItem(label: label, path: path, program: program, kind: kind,
                                        runAtLoad: runAtLoad, keepAlive: keepAlive,
                                        disabled: override ?? plistDisabled, running: running))
            }
        }
        return items
    }

    /// `launchctl print-disabled <domain>` を解析
    private static func disabledMap(domain: String) -> [String: Bool] {
        let r = Shell.run("/bin/launchctl", ["print-disabled", domain])
        var map: [String: Bool] = [:]
        for line in r.out.split(separator: "\n") where line.contains("=>") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            map[label] = (value == "disabled" || value == "true")
        }
        return map
    }

    /// `launchctl list` → [label: pid?]
    private static func launchctlList() -> [String: Int?] {
        let r = Shell.run("/bin/launchctl", ["list"])
        var map: [String: Int?] = [:]
        for line in r.out.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t")
            guard cols.count >= 3 else { continue }
            map[String(cols[2])] = .some(Int(cols[0]))
        }
        return map
    }

    /// 有効化 / 無効化。成功したら nil、管理者権限が必要ならそのコマンドを返す。
    static func setEnabled(_ item: LaunchItem, enabled: Bool) -> (ok: Bool, adminCommand: String?) {
        let label = item.label
        switch item.kind {
        case .userAgent, .globalAgent:
            let domain = "gui/\(getuid())"
            if enabled {
                let r = Shell.run("/bin/launchctl", ["enable", "\(domain)/\(label)"])
                Shell.run("/bin/launchctl", ["bootstrap", domain, item.path])
                if r.status == 0 { return (true, nil) }
            } else {
                let r = Shell.run("/bin/launchctl", ["disable", "\(domain)/\(label)"])
                Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
                if r.status == 0 { return (true, nil) }
            }
            let cmd = enabled
                ? "launchctl enable \(Shell.quote(domain + "/" + label)); launchctl bootstrap \(domain) \(Shell.quote(item.path))"
                : "launchctl disable \(Shell.quote(domain + "/" + label)); launchctl bootout \(Shell.quote(domain + "/" + label))"
            return (false, cmd)
        case .daemon:
            let cmd = enabled
                ? "launchctl enable \(Shell.quote("system/" + label)); launchctl bootstrap system \(Shell.quote(item.path)); true"
                : "launchctl disable \(Shell.quote("system/" + label)); launchctl bootout \(Shell.quote("system/" + label)); true"
            return (false, cmd)
        }
    }
}
