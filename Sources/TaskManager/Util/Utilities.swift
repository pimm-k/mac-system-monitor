import Foundation
import Darwin
import SwiftUI

// MARK: - 書式

enum Fmt {
    static func bytes(_ b: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = max(0, b)
        var i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i == 0 { return "\(Int(v)) B" }
        return String(format: v >= 100 ? "%.0f" : "%.1f", v) + " " + units[i]
    }

    static func bytes(_ b: UInt64) -> String { bytes(Double(b)) }

    static func rate(_ bytesPerSec: Double) -> String { bytes(bytesPerSec) + "/秒" }

    /// ネットワーク用 (ビット/秒, 1000 基準)
    static func bits(_ bytesPerSec: Double) -> String {
        let units = ["bps", "Kbps", "Mbps", "Gbps"]
        var v = max(0, bytesPerSec * 8)
        var i = 0
        while v >= 1000 && i < units.count - 1 {
            v /= 1000
            i += 1
        }
        return String(format: i == 0 ? "%.0f" : "%.1f", v) + " " + units[i]
    }

    static func percent(_ p: Double) -> String { String(format: "%.1f%%", p) }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        return String(format: "%d:%02d:%02d:%02d", d, h, m, sec)
    }

    static func cpuTime(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

// MARK: - sysctl

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    static func int(_ name: String) -> Int? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return Int(v)
    }
}

/// C の固定長 char 配列 (タプル) を String へ
func tupleString<T>(_ value: T) -> String {
    withUnsafeBytes(of: value) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

// MARK: - プロセスの同一性確認 (PID 再利用対策)

enum ProcIdentity {
    /// 実行ファイルのパス (取得できなければ空文字)
    static func path(_ pid: pid_t) -> String {
        var buf = [UInt8](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard len > 0 else { return "" }
        return String(decoding: buf.prefix(Int(len)), as: UTF8.self)
    }

    /// 一覧に表示していたプロセスと、今その PID で動いているプロセスが同じか
    static func matches(pid: pid_t, expectedPath: String?) -> Bool {
        guard let expected = expectedPath, !expected.isEmpty else { return true }
        return path(pid) == expected
    }

    /// ps が表示するコマンド名 (管理者コマンド内での再確認用)
    static func psComm(_ pid: pid_t) -> String? {
        let r = Shell.run("/bin/ps", ["-p", String(pid), "-o", "comm="])
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !s.isEmpty ? s : nil
    }

    /// 「実行直前にまだ同じプロセスなら実行する」シェル断片を作る
    static func guarded(pid: pid_t, command: String) -> String? {
        guard let comm = psComm(pid) else { return nil }
        return "[ \"$(/bin/ps -p \(pid) -o comm=)\" = \(Shell.quote(comm)) ] && \(command)"
    }
}

// MARK: - シェル実行

enum Shell {
    struct Result { let status: Int32; let out: String; let err: String }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return Result(status: -1, out: "", err: error.localizedDescription)
        }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      out: String(decoding: o, as: UTF8.self),
                      err: String(decoding: e, as: UTF8.self))
    }

    /// シェル用にシングルクォートでエスケープ
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - 色 (Windows タスクマネージャー風)

enum Palette {
    static let cpu = Color(red: 0.07, green: 0.49, blue: 0.86)
    static let memory = Color(red: 0.55, green: 0.17, blue: 0.70)
    static let disk = Color(red: 0.30, green: 0.62, blue: 0.08)
    static let network = Color(red: 0.70, green: 0.36, blue: 0.02)
    static let gpu = Color(red: 0.0, green: 0.55, blue: 0.62)

    /// ヒートマップ (0...1)
    static func heat(_ level: Double) -> Color {
        let l = min(max(level, 0), 1)
        return Color(red: 1.0, green: 0.82 - 0.35 * l, blue: 0.25 - 0.2 * l).opacity(0.10 + 0.55 * l)
    }
}
