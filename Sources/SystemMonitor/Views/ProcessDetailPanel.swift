import SwiftUI
import AppKit

// MARK: - 詳細パネルのタブ

enum ProcessDetailTab: String, CaseIterable, Identifiable {
    case overview, performance, network, files
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return L("概要")
        case .performance: return L("パフォーマンス")
        case .network: return L("ネットワーク")
        case .files: return L("署名・ファイル")
        }
    }
}

// MARK: - 状態

/// 選んだプロセスの詳細と、そのプロセスの使用量の推移を保持する
@MainActor
final class ProcessDetailModel: ObservableObject {
    @Published var tab: ProcessDetailTab = ProcessDetailTab(rawValue: UserDefaults.standard.string(forKey: "processDetailTab") ?? "") ?? .overview {
        didSet {
            UserDefaults.standard.set(tab.rawValue, forKey: "processDetailTab")
            loadTabIfNeeded()
        }
    }
    @Published private(set) var pid: pid_t?
    @Published private(set) var path = ""
    @Published private(set) var startTime: Date?
    @Published private(set) var arguments: [String]?
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memHistory: [Double] = []
    @Published private(set) var diskHistory: [Double] = []
    @Published private(set) var connections: [NetConn]?
    @Published private(set) var signature: SignatureInfo??
    @Published private(set) var openFiles: [String]?
    @Published private(set) var loading = false

    /// 表示するプロセスを切り替える
    func select(_ p: ProcItem?) {
        guard p?.pid != pid || p?.path != path else { return }
        pid = p?.pid
        path = p?.path ?? ""
        startTime = nil
        arguments = nil
        cpuHistory = []; memHistory = []; diskHistory = []
        connections = nil; signature = nil; openFiles = nil
        guard let p else { return }
        let target = p.pid
        Task.detached(priority: .userInitiated) {
            let start = ProcessInspector.startTime(target)
            let args = ProcessInspector.arguments(target)
            await MainActor.run {
                guard self.pid == target else { return }
                self.startTime = start
                self.arguments = args
            }
        }
        loadTabIfNeeded()
    }

    /// 毎回の更新で使用量を記録する
    func record(_ p: ProcItem) {
        guard p.pid == pid else { return }
        append(&cpuHistory, p.cpu)
        append(&memHistory, Double(p.memory))
        append(&diskHistory, p.disk)
    }

    /// ネットワーク・ファイルのタブは開いたときに取得する (lsof は少し重いため)
    func loadTabIfNeeded(force: Bool = false) {
        guard let target = pid else { return }
        let path = self.path
        switch tab {
        case .network:
            guard force || connections == nil else { return }
            loading = true
            Task.detached(priority: .userInitiated) {
                let list = NetConnections.list(pid: target)
                await MainActor.run {
                    guard self.pid == target else { return }
                    self.connections = list
                    self.loading = false
                }
            }
        case .files:
            guard force || signature == nil else { return }
            loading = true
            Task.detached(priority: .userInitiated) {
                let sig = ProcessInspector.signature(path: path)
                let files = ProcessInspector.openFiles(target)
                await MainActor.run {
                    guard self.pid == target else { return }
                    self.signature = .some(sig)
                    self.openFiles = files
                    self.loading = false
                }
            }
        default:
            break
        }
    }

    private func append(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > Monitor.historyLength { a.removeFirst(a.count - Monitor.historyLength) }
    }
}

// MARK: - パネル

/// プロセス タブの右側に出す詳細パネル
@MainActor
struct ProcessDetailPanel: View {
    @Environment(\.uiScale) private var ui
    @EnvironmentObject private var m: Monitor
    @ObservedObject var model: ProcessDetailModel
    /// アプリとしてまとめて表示している行なら true (終了時にアプリとして終了する)
    let isApp: Bool
    let onClose: () -> Void
    @StateObject private var confirmForceBox = Box<Bool>(false)

    private var item: ProcItem? {
        guard let pid = model.pid else { return nil }
        return m.processes.first { $0.pid == pid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("詳細")).scaledFont(.headline).foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) { Image(systemName: "sidebar.right") }
                    .buttonStyle(.borderless)
                    .help(L("詳細パネルを隠す"))
            }
            .padding(.horizontal, 14 * ui).padding(.top, 10 * ui).padding(.bottom, 4 * ui)
            Divider()
            if let p = item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12 * ui) {
                        header(p)
                        Picker("", selection: $model.tab) {
                            ForEach(ProcessDetailTab.allCases) { t in Text(t.title).tag(t) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        switch model.tab {
                        case .overview: overview(p)
                        case .performance: performance(p)
                        case .network: network(p)
                        case .files: files(p)
                        }
                    }
                    .padding(14 * ui)
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "sidebar.right").scaledFont(.largeTitle).foregroundStyle(.tertiary)
                    Text(model.pid == nil ? L("プロセスを選ぶと詳細を表示します") : L("このプロセスは終了しました"))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .onReceive(m.$processes) { list in
            if let pid = model.pid, let p = list.first(where: { $0.pid == pid }) { model.record(p) }
        }
        .confirmationDialog(L("選択したプロセスを強制終了しますか？"), isPresented: $confirmForceBox.value) {
            Button(L("強制終了"), role: .destructive) {
                if let pid = model.pid { m.endTask(pids: [pid], force: true, preferApp: isApp) }
            }
        } message: {
            Text(L("保存されていないデータは失われます。"))
        }
    }

    // MARK: 見出し

    private func header(_ p: ProcItem) -> some View {
        VStack(alignment: .leading, spacing: 8 * ui) {
            HStack(spacing: 10 * ui) {
                Image(nsImage: IconCache.shared.icon(path: p.path, bundlePath: p.bundlePath))
                    .resizable().frame(width: 40 * ui, height: 40 * ui)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).scaledFont(size: 17, weight: .semibold).lineLimit(1).textSelection(.enabled)
                    Text(L("PID %@ ・ %@ ・ ユーザー %@", "\(p.pid)", p.statusLong, p.user))
                        .scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                Button(L("タスクの終了")) { m.endTask(pids: [p.pid], force: false, preferApp: isApp) }
                Button(L("強制終了")) { confirmForceBox.value = true }
                    .foregroundStyle(.red)
                Spacer()
                Button {
                    m.revealInFinder(path: p.bundlePath ?? p.path)
                } label: { Image(systemName: "folder") }
                    .help(L("ファイルの場所を開く"))
                    .disabled(p.path.isEmpty)
            }
            .controlSize(.small)
        }
    }

    // MARK: ① 概要

    private func overview(_ p: ProcItem) -> some View {
        let parent = m.processes.first { $0.pid == p.ppid }
        let children = m.processes.filter { $0.ppid == p.pid }
        let unknown = L("取得できません")
        var rows: [(String, String)] = [
            (L("パス"), p.path.isEmpty ? unknown : p.path),
            (L("引数"), model.arguments.map { $0.isEmpty ? "—" : $0.joined(separator: " ") } ?? unknown),
            (L("親プロセス"), parent.map { "\($0.name) (PID \($0.pid))" } ?? "PID \(p.ppid)"),
        ]
        if let start = model.startTime {
            rows.append((L("起動時刻"), L("%@（実行時間 %@）", Self.dateFormatter.string(from: start),
                                       Self.elapsed(Date().timeIntervalSince(start)))))
        }
        rows += [
            (L("優先度"), "\(p.nice)"),
            (L("スレッド"), p.limited ? "—" : "\(p.threads)"),
            (L("CPU 時間"), Fmt.cpuTime(p.cpuTime)),
            (L("子プロセス"), children.isEmpty ? L("なし")
                : L("%@ 個（%@ など）", "\(children.count)", children.prefix(2).map(\.name).joined(separator: "、"))),
        ]
        return VStack(alignment: .leading, spacing: 12 * ui) {
            InfoGrid(rows: rows)
            HStack(spacing: 8 * ui) {
                mini("CPU", Fmt.percent(p.cpu), model.cpuHistory, Palette.cpu, max: 100)
                mini(L("メモリ"), Fmt.bytes(p.memory), model.memHistory, Palette.memory,
                     max: niceMax(model.memHistory, minimum: 64 * 1_048_576))
                mini(L("ディスク"), Fmt.rate(p.disk), model.diskHistory, Palette.disk,
                     max: niceMax(model.diskHistory, minimum: 1_048_576))
            }
            if p.limited {
                Text(L("他のユーザー (root など) のプロセスのため、一部の情報は取得できません。"))
                    .scaledFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func mini(_ title: String, _ value: String, _ values: [Double], _ color: Color, max: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).scaledFont(.caption).foregroundStyle(.secondary)
            Text(value).scaledFont(size: 14, weight: .semibold).lineLimit(1).minimumScaleFactor(0.7)
            LineGraph(series: [GraphSeries(values: values, color: color)], maxValue: max, frameColor: color, gridDivisions: 0)
                .frame(height: 36 * ui)
        }
        .padding(8 * ui)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
    }

    // MARK: ② パフォーマンス

    private func performance(_ p: ProcItem) -> some View {
        let memMax = niceMax(model.memHistory, minimum: 64 * 1_048_576)
        let diskMax = niceMax(model.diskHistory, minimum: 1_048_576)
        return VStack(alignment: .leading, spacing: 6 * ui) {
            graphTitle(L("CPU 使用率"), Fmt.percent(p.cpu), "100%")
            LineGraph(series: [GraphSeries(values: model.cpuHistory, color: Palette.cpu)], maxValue: 100, frameColor: Palette.cpu)
                .frame(height: 110 * ui)
            graphTitle(L("メモリ"), Fmt.bytes(p.memory), Fmt.bytes(memMax))
            LineGraph(series: [GraphSeries(values: model.memHistory, color: Palette.memory)], maxValue: memMax, frameColor: Palette.memory)
                .frame(height: 90 * ui)
            graphTitle(L("ディスク"), Fmt.rate(p.disk), Fmt.rate(diskMax))
            LineGraph(series: [GraphSeries(values: model.diskHistory, color: Palette.disk)], maxValue: diskMax, frameColor: Palette.disk)
                .frame(height: 70 * ui)
            Text(L("このパネルを開いている間の推移（最大 60 回分）。アプリの場合、ヘルパーなどの子プロセスは含みません。"))
                .scaledFont(.caption).foregroundStyle(.secondary)
        }
    }

    private func graphTitle(_ title: String, _ value: String, _ top: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).scaledFont(.callout)
            Text(value).scaledFont(.callout).bold()
            Spacer()
            Text(top).scaledFont(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 4 * ui)
    }

    // MARK: ③ ネットワーク

    @ViewBuilder private func network(_ p: ProcItem) -> some View {
        VStack(alignment: .leading, spacing: 8 * ui) {
            HStack {
                if let list = model.connections {
                    let ext = list.filter { !$0.isListen && !($0.remoteHost.map(NetConnections.isLocal) ?? true) }.count
                    let listen = list.filter(\.isListen).count
                    Text(L("外部への接続 %@ 件 ・ 待ち受け %@ 件", "\(ext)", "\(listen)"))
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button(L("再読み込み")) { model.loadTabIfNeeded(force: true) }.controlSize(.small)
            }
            if let list = model.connections {
                if list.isEmpty {
                    Text(p.limited ? L("他のユーザー (root など) のプロセスのため、接続を取得できません。")
                                   : L("ネットワーク接続はありません。"))
                        .foregroundStyle(.secondary).padding(.vertical, 8)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 12 * ui, verticalSpacing: 4 * ui) {
                        GridRow {
                            Text(L("種類")); Text(L("接続先")); Text(L("状態"))
                        }
                        .scaledFont(.caption).foregroundStyle(.secondary)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(Array(list.enumerated()), id: \.offset) { _, c in
                            GridRow {
                                Text(c.proto)
                                Text(c.remoteText).scaledFont(.callout, mono: true).textSelection(.enabled).lineLimit(1)
                                Text(c.isListen ? L("待ち受け") : (c.state.isEmpty ? "—" : c.state))
                                    .foregroundStyle(.secondary)
                            }
                            .scaledFont(.callout)
                        }
                    }
                }
            }
        }
    }

    // MARK: ④ 署名・ファイル

    @ViewBuilder private func files(_ p: ProcItem) -> some View {
        VStack(alignment: .leading, spacing: 10 * ui) {
            HStack {
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button(L("再読み込み")) { model.loadTabIfNeeded(force: true) }.controlSize(.small)
            }
            if let sigOpt = model.signature {
                if let s = sigOpt {
                    InfoGrid(rows: [
                        (L("コード署名"), signatureText(s)),
                        (L("署名者"), s.signer ?? (s.adhoc ? L("アドホック署名（開発者の証明書なし）") : "—")),
                        (L("チーム ID"), s.teamID ?? "—"),
                    ])
                } else {
                    Text(L("署名を確認できません。")).foregroundStyle(.secondary)
                }
            }
            if let list = model.openFiles {
                Text(L("開いているファイル（%@ 件）", "\(list.count)"))
                    .scaledFont(.caption).foregroundStyle(.secondary).padding(.top, 4)
                if list.isEmpty {
                    Text(p.limited ? L("他のユーザー (root など) のプロセスのため、開いているファイルを取得できません。")
                                   : L("開いているファイルはありません。"))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(list, id: \.self) { f in
                            Text(f.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .scaledFont(.caption, mono: true)
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(f)
                        }
                    }
                }
            }
        }
    }

    private func signatureText(_ s: SignatureInfo) -> String {
        if s.unsigned { return L("⚠️ 署名なし") }
        if !s.valid { return L("⚠️ 署名が壊れています（改ざんの可能性）") }
        if s.isApple { return L("✓ 有効（Apple）") }
        if s.adhoc { return L("✓ 有効（アドホック署名）") }
        return L("✓ 有効")
    }

    // MARK: 補助

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm:ss"
        return f
    }()

    private static func elapsed(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return L("%@ 日 %@ 時間", "\(d)", "\(h)") }
        if h > 0 { return L("%@ 時間 %@ 分", "\(h)", "\(m)") }
        return L("%@ 分", "\(m)")
    }

}
