import SwiftUI

enum PerfItem: Hashable {
    case cpu, memory, disk, network(String), gpu

    /// 保存用の文字列 (例: "cpu", "network:en0")
    var key: String {
        switch self {
        case .cpu: return "cpu"
        case .memory: return "memory"
        case .disk: return "disk"
        case .network(let id): return "network:" + id
        case .gpu: return "gpu"
        }
    }

    init(key: String) {
        switch key {
        case "memory": self = .memory
        case "disk": self = .disk
        case "gpu": self = .gpu
        default:
            if key.hasPrefix("network:") {
                self = .network(String(key.dropFirst("network:".count)))
            } else {
                self = .cpu
            }
        }
    }
}

enum CPUGraphMode: String, CaseIterable, Identifiable {
    case overall, logical
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overall: return L("全体の使用率")
        case .logical: return L("論理プロセッサ")
        }
    }
}

@MainActor
struct PerformanceView: View {
    @Environment(\.uiScale) private var ui
    @EnvironmentObject private var m: Monitor
    /// 選択中の項目 (Monitor 経由で保存され、次回起動時に復元される)
    private var selected: PerfItem {
        get { m.perfItem }
        nonmutating set { m.perfItem = newValue }
    }
    /// CPU グラフの表示モード (全体 / 論理プロセッサ)
    private var cpuMode: CPUGraphMode {
        get { m.cpuGraphMode }
        nonmutating set { m.cpuGraphMode = newValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) { cards }.padding(8)
            }
            .frame(width: 250 * ui)
            Divider()
            ScrollView {
                detail
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - 左側のカード

    @ViewBuilder private var cards: some View {
        let s = m.system
        card(.cpu, "CPU", "\(Fmt.percent(s.cpu.total))", m.cpuHistory, 100, Palette.cpu)
        card(.memory, L("メモリ"),
             "\(Fmt.bytes(s.mem.used)) / \(Fmt.bytes(s.mem.total)) (\(Int(s.mem.percent))%)",
             m.memHistory, 100, Palette.memory)
        card(.disk, L("ディスク 0 (%@)", "\(s.disk.name)"), "SSD  \(Int(s.disk.active))%",
             m.diskActiveHistory, 100, Palette.disk)
        ForEach(s.nets) { n in
            let rx = m.netRxHistory[n.id] ?? [], tx = m.netTxHistory[n.id] ?? []
            card(.network(n.id), n.name,
                 L("送信: %@\n受信: %@", "\(Fmt.bits(n.tx))", "\(Fmt.bits(n.rx))"),
                 rx, niceMax(rx + tx), Palette.network, second: tx)
        }
        if let g = s.gpu {
            card(.gpu, "GPU 0", "\(g.name)\n\(Int(g.utilization))%", m.gpuHistory, 100, Palette.gpu)
        }
    }

    private func card(_ item: PerfItem, _ title: String, _ subtitle: String,
                      _ values: [Double], _ maxV: Double, _ color: Color, second: [Double]? = nil) -> some View {
        var series = [GraphSeries(values: values, color: color)]
        if let second { series.append(GraphSeries(values: second, color: color, filled: false, dashed: true)) }
        return Button { selected = item } label: {
            HStack(spacing: 10) {
                LineGraph(series: series, maxValue: maxV, frameColor: color, gridDivisions: 0)
                    .frame(width: 72 * ui, height: 48 * ui)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).scaledFont(.headline).lineLimit(1)
                    Text(subtitle).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(selected == item ? Color.accentColor.opacity(0.18) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 右側の詳細

    @ViewBuilder private var detail: some View {
        switch selected {
        case .cpu: cpuDetail
        case .memory: memoryDetail
        case .disk: diskDetail
        case .network(let id):
            if let n = m.system.nets.first(where: { $0.id == id }) { networkDetail(n) } else { cpuDetail }
        case .gpu: gpuDetail
        }
    }

    private func header(_ title: String, _ sub: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).scaledFont(size: 30, weight: .semibold)
            Spacer()
            Text(sub).scaledFont(.title3).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func axis(_ top: String, _ right: String = "100%") -> some View {
        HStack { Text(top); Spacer(); Text(right) }
            .scaledFont(.caption).foregroundStyle(.secondary)
    }

    private var bottomAxis: some View {
        HStack { Text(L("60 秒")); Spacer(); Text("0") }
            .scaledFont(.caption).foregroundStyle(.secondary)
    }

    // CPU
    private var cpuDetail: some View {
        let s = m.system, info = m.staticInfo
        let coreCount = m.coreHistory.count
        return VStack(alignment: .leading, spacing: 10) {
            header("CPU", info.cpuBrand)

            // グラフの切り替え
            HStack(spacing: 12) {
                Picker(L("グラフの変更"), selection: $m.cpuGraphMode) {
                    ForEach(CPUGraphMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260 * ui)

                Spacer()
            }

            Group {
                if cpuMode == .logical && coreCount > 0 {
                    coreGrid
                } else {
                    axis(L("% 使用率"))
                    LineGraph(series: [GraphSeries(values: m.cpuHistory, color: Palette.cpu)],
                              maxValue: 100, frameColor: Palette.cpu)
                        .frame(height: 300 * ui)
                    bottomAxis
                }
            }
            .contextMenu {
                Menu(L("グラフの変更")) {
                    Button(L("全体の使用率")) { cpuMode = .overall }
                    Button(L("論理プロセッサ")) { cpuMode = .logical }
                }
            }

            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 32) {
                        Stat(label: L("使用率"), value: Fmt.percent(s.cpu.total))
                        Stat(label: L("ユーザー / システム"),
                             value: "\(Int(s.cpu.user))% / \(Int(s.cpu.system))%")
                    }
                    HStack(spacing: 32) {
                        Stat(label: L("プロセス"), value: "\(m.processes.count)")
                        Stat(label: L("スレッド"), value: "\(m.totalThreads)")
                    }
                    HStack(spacing: 32) {
                        Stat(label: L("稼働時間"), value: Fmt.duration(s.uptime))
                        Stat(label: L("ロードアベレージ"),
                             value: s.load.map { String(format: "%.2f", $0) }.joined(separator: " "))
                    }
                }
                InfoGrid(rows: [
                    (L("物理コア"), "\(info.physicalCores)"),
                    (L("論理プロセッサ"), "\(info.logicalCores)"),
                    (L("P コア / E コア"), info.pCores.map { p in "\(p) / \(info.eCores ?? 0)" } ?? "—"),
                    (L("アーキテクチャ"), info.arch),
                    (L("モデル"), info.model),
                    ("OS", info.osVersion),
                ])
            }
        }
    }

    /// 論理プロセッサの一覧 (クリックで拡大)
    private var coreGrid: some View {
        let n = m.coreHistory.count
        return VStack(alignment: .leading, spacing: 10 * ui) {
            HStack(spacing: 12 * ui) {
                Text(L("% 使用率 (論理プロセッサごと)")).scaledFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker(L("列数"), selection: $m.cpuColumns) {
                    Text(L("列数: 自動")).tag(0)
                    Text(L("2 列")).tag(2)
                    Text(L("4 列")).tag(4)
                    Text(L("8 列")).tag(8)
                }
                .labelsHidden()
                .fixedSize()
            }
            LazyVGrid(columns: gridColumns(for: n), spacing: 6 * ui) {
                ForEach(0..<n, id: \.self) { i in coreTile(i) }
            }
            HStack { Text(L("60 秒")); Spacer(); Text("0") }
                .scaledFont(.caption).foregroundStyle(.secondary)
        }
    }

    private func coreTile(_ i: Int) -> some View {
        LineGraph(series: [GraphSeries(values: m.coreHistory[i], color: Palette.cpu)],
                  maxValue: 100, frameColor: Palette.cpu, gridDivisions: 4)
            .frame(height: 86 * ui)
            .overlay(alignment: .topLeading) {
                Text("CPU \(i)  \(coreKind(i))")
                    .scaledFont(.caption2).foregroundStyle(.secondary).padding(3 * ui)
            }
            .overlay(alignment: .topTrailing) {
                Text("\(Int((m.coreHistory[i].last ?? 0).rounded()))%")
                    .scaledFont(.caption2, mono: true).foregroundStyle(.secondary).padding(3 * ui)
            }
    }

    /// 列数: 指定があればその数。自動なら 16 個以下は半分ずつ 2 段 (8 個 → 4 列 × 2 段: 0〜3 / 4〜7)
    private func gridColumns(for count: Int) -> [GridItem] {
        let auto = count <= 16 ? max(1, (count + 1) / 2) : 8
        let cols = m.cpuColumns > 0 ? m.cpuColumns : auto
        return Array(repeating: GridItem(.flexible(), spacing: 6 * ui), count: cols)
    }

    /// Apple Silicon では先頭の論理プロセッサが E コア
    private func coreKind(_ i: Int) -> String {
        guard let e = m.staticInfo.eCores, e > 0, m.staticInfo.pCores != nil else { return "" }
        return i < e ? "E" : "P"
    }

    // メモリ
    private var memoryDetail: some View {
        let mem = m.system.mem
        return VStack(alignment: .leading, spacing: 10) {
            header(L("メモリ"), Fmt.bytes(mem.total))
            axis(L("メモリ使用量"), Fmt.bytes(mem.total))
            LineGraph(series: [GraphSeries(values: m.memHistory, color: Palette.memory)],
                      maxValue: 100, frameColor: Palette.memory)
                .frame(height: 260 * ui)
            bottomAxis

            Text(L("メモリの構成")).scaledFont(.caption).foregroundStyle(.secondary).padding(.top, 6)
            MemoryBar(mem: mem).frame(height: 36 * ui)

            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 32) {
                        Stat(label: L("使用中 (圧縮)"), value: "\(Fmt.bytes(mem.used)) (\(Fmt.bytes(mem.compressed)))")
                        Stat(label: L("利用可能"), value: Fmt.bytes(mem.available))
                    }
                    HStack(spacing: 32) {
                        Stat(label: L("キャッシュ済み"), value: Fmt.bytes(mem.cached))
                        Stat(label: L("スワップ使用量"), value: "\(Fmt.bytes(mem.swapUsed)) / \(Fmt.bytes(mem.swapTotal))")
                    }
                }
                InfoGrid(rows: [
                    (L("アプリ メモリ"), Fmt.bytes(mem.app)),
                    (L("確保されているメモリ"), Fmt.bytes(mem.wired)),
                    (L("圧縮"), Fmt.bytes(mem.compressed)),
                    (L("キャッシュされたファイル"), Fmt.bytes(mem.cached)),
                ])
            }
        }
    }

    // ディスク
    private var diskDetail: some View {
        let d = m.system.disk
        let tMax = niceMax(m.diskReadHistory + m.diskWriteHistory, minimum: 1_048_576)
        return VStack(alignment: .leading, spacing: 10) {
            header(L("ディスク 0 (%@)", "\(d.name)"), L("起動ディスク"))
            axis(L("アクティブな時間"))
            LineGraph(series: [GraphSeries(values: m.diskActiveHistory, color: Palette.disk)],
                      maxValue: 100, frameColor: Palette.disk)
                .frame(height: 180 * ui)
            bottomAxis
            axis(L("ディスク転送速度"), Fmt.rate(tMax))
            LineGraph(series: [GraphSeries(values: m.diskReadHistory, color: Palette.disk),
                               GraphSeries(values: m.diskWriteHistory, color: Palette.disk, filled: false, dashed: true)],
                      maxValue: tMax, frameColor: Palette.disk)
                .frame(height: 120 * ui)
            HStack(spacing: 16) {
                Label(L("読み取り"), systemImage: "line.diagonal").foregroundStyle(Palette.disk)
                Label(L("書き込み (破線)"), systemImage: "line.diagonal").foregroundStyle(.secondary)
            }
            .scaledFont(.caption)

            HStack(alignment: .top, spacing: 48) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 32) {
                        Stat(label: L("アクティブな時間"), value: "\(Int(d.active))%")
                        Stat(label: L("読み取り速度"), value: Fmt.rate(d.readRate))
                        Stat(label: L("書き込み速度"), value: Fmt.rate(d.writeRate))
                    }
                }
                InfoGrid(rows: [
                    (L("容量"), Fmt.bytes(d.capacity)),
                    (L("空き容量"), Fmt.bytes(d.available)),
                    (L("使用済み"), Fmt.bytes(d.capacity > d.available ? d.capacity - d.available : 0)),
                ])
            }
        }
    }

    // ネットワーク
    private func networkDetail(_ n: NetSnapshot) -> some View {
        let rx = m.netRxHistory[n.id] ?? [], tx = m.netTxHistory[n.id] ?? []
        let maxV = niceMax(rx + tx)
        return VStack(alignment: .leading, spacing: 10) {
            header(n.name, n.id)
            axis(L("スループット"), Fmt.bits(maxV))
            LineGraph(series: [GraphSeries(values: rx, color: Palette.network),
                               GraphSeries(values: tx, color: Palette.network, filled: false, dashed: true)],
                      maxValue: maxV, frameColor: Palette.network)
                .frame(height: 300 * ui)
            bottomAxis
            HStack(spacing: 16) {
                Label(L("受信"), systemImage: "line.diagonal").foregroundStyle(.secondary)
                Label(L("送信 (破線)"), systemImage: "line.diagonal").foregroundStyle(.secondary)
            }
            .scaledFont(.caption)

            HStack(alignment: .top, spacing: 48) {
                HStack(spacing: 32) {
                    Stat(label: L("送信"), value: Fmt.bits(n.tx))
                    Stat(label: L("受信"), value: Fmt.bits(n.rx))
                }
                InfoGrid(rows: [
                    (L("アダプター名"), n.name),
                    (L("BSD 名"), n.id),
                    (L("MAC アドレス"), n.mac ?? "—"),
                    (L("IPv4 アドレス"), n.ipv4.isEmpty ? "—" : n.ipv4.joined(separator: "\n")),
                    (L("IPv6 アドレス"), n.ipv6.isEmpty ? "—" : n.ipv6.joined(separator: "\n")),
                ])
            }
        }
    }

    // GPU
    private var gpuDetail: some View {
        let g = m.system.gpu ?? GPUSnapshot()
        return VStack(alignment: .leading, spacing: 10) {
            header("GPU", g.name)
            axis(L("使用率"))
            LineGraph(series: [GraphSeries(values: m.gpuHistory, color: Palette.gpu)],
                      maxValue: 100, frameColor: Palette.gpu)
                .frame(height: 300 * ui)
            bottomAxis
            HStack(alignment: .top, spacing: 48) {
                HStack(spacing: 32) {
                    Stat(label: L("使用率"), value: "\(Int(g.utilization))%")
                    Stat(label: L("使用中の GPU メモリ"), value: Fmt.bytes(g.memoryUsed))
                }
                InfoGrid(rows: [
                    (L("名前"), g.name),
                    (L("GPU コア"), g.cores.map { String($0) } ?? "—"),
                ])
            }
        }
    }
}

/// メモリ構成バー
private struct MemoryBar: View {
    @Environment(\.uiScale) private var ui
    let mem: MemSnapshot
    var body: some View {
        let total = Double(max(mem.total, 1))
        let parts: [(String, UInt64, Double)] = [
            (L("アプリ"), mem.app, 0.85),
            (L("確保"), mem.wired, 0.6),
            (L("圧縮"), mem.compressed, 0.4),
            (L("キャッシュ"), mem.cached, 0.18),
        ]
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(parts.indices, id: \.self) { i in
                    let w = geo.size.width * CGFloat(min(Double(parts[i].1) / total, 1))
                    Rectangle()
                        .fill(Palette.memory.opacity(parts[i].2))
                        .frame(width: max(w - 1, 0))
                        .help("\(parts[i].0): \(Fmt.bytes(parts[i].1))")
                }
                Spacer(minLength: 0)
            }
            .overlay(Rectangle().stroke(Palette.memory.opacity(0.7), lineWidth: 1))
        }
    }
}
