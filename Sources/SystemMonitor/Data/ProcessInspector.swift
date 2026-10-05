import Foundation
import Darwin
import Security

/// コード署名の詳細 (詳細パネル用)
struct SignatureInfo: Sendable {
    var valid: Bool
    var unsigned: Bool
    var adhoc: Bool
    var signer: String?      // 証明書の名前 (例: Developer ID Application: Google LLC (XXXX))
    var teamID: String?
    var isApple: Bool
}

/// 1 プロセスの詳しい情報を取得する (詳細パネル用)。
/// 他ユーザー (root など) のプロセスは macOS の権限上、取得できない項目がある。
enum ProcessInspector {
    /// 起動時刻 (sysctl KERN_PROC_PID。他ユーザーのプロセスでも取得できる)
    static func startTime(_ pid: pid_t) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// コマンドライン引数 (sysctl KERN_PROCARGS2。取得できなければ nil)。先頭 (実行ファイル名) は除く
    static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        guard argc > 0, argc < 10_000 else { return [] }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }   // 実行ファイルのパス
        while i < size && buf[i] == 0 { i += 1 }   // 区切りの 0
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return Array(args.dropFirst())
    }

    /// コード署名の情報
    static func signature(path: String) -> SignatureInfo? {
        guard !path.isEmpty else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        let status = CodeSignature.status(of: path)
        var infoCF: CFDictionary?
        let signingInformation = SecCSFlags(rawValue: 1 << 1)   // kSecCSSigningInformation
        SecCodeCopySigningInformation(code, signingInformation, &infoCF)
        let dict = (infoCF as? [String: Any]) ?? [:]
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let signer = certs?.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let adhoc = flags & 0x2 != 0   // kSecCodeSignatureAdhoc
        let isApple = signer == "Software Signing" || (signer?.hasPrefix("Apple") ?? false)
        return SignatureInfo(valid: status == .valid, unsigned: status == .unsigned, adhoc: adhoc,
                             signer: signer, teamID: team, isApple: isApple)
    }

    /// 開いている通常ファイル (lsof。最大 300 件)
    static func openFiles(_ pid: pid_t) -> [String] {
        let r = Shell.run("/usr/sbin/lsof", ["-nP", "-w", "-p", String(pid), "-F", "tn"])
        var out: [String] = []
        var seen = Set<String>()
        var type = ""
        for line in r.out.split(separator: "\n") {
            guard let f = line.first else { continue }
            let v = String(line.dropFirst())
            switch f {
            case "f": type = ""
            case "t": type = v
            case "n":
                if type == "REG", !v.isEmpty, seen.insert(v).inserted {
                    out.append(v)
                    if out.count >= 300 { return out }
                }
            default: break
            }
        }
        return out
    }
}
