import SwiftUI
import AppKit
import Charts

// MARK: - 期間・表示の種類

enum HistoryRange: String, CaseIterable, Identifiable {
    case h1, h6, d1, d7, d30
    var id: String { rawValue }
    var title: String {
        switch self {
        case .h1: return "1時間"
        case .h6: return "6時間"
        case .d1: return "24時間"
        case .d7: return "7日"
        case .d30: return "30日"
        }
    }
    var seconds: Int64 {
        switch self {
        case .h1: return 3600
        case .h6: return 6 * 3600
        case .d1: return 24 * 3600
        case .d7: return 7 * 86400
        case .d30: return 30 * 86400
        }
    }
}

enum HistorySection: String, CaseIterable, Identifiable {
    case graphs, apps, spikes, events
    var id: String { rawValue }
    var title: String {
        switch self {
        case .graphs: return "推移グラフ"
        case .apps: return "アプリの履歴"
        case .spikes: return "高負荷の記録"
        case .events: return "起動・終了ログ"
        }
    }
}

// MARK: - 画面の状態

@MainActor
final class HistoryModel: ObservableObject {
    private enum Keys {
        static let range = "historyRange"
        static let section = "historySection"
    }

    @Published var range: HistoryRange = HistoryRange(rawValue: UserDefaults.standard.string(forKey: Keys.range) ?? "") ?? .h1 {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: Keys.range) }
    }
    @Published var section: HistorySection = HistorySection(rawValue: UserDefaults.standard.string(forKey: Keys.section) ?? "") ?? .graphs {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: Keys.section) }
    }
    @Published var hoverTs: Int64? = nil

    @Published private(set) var points: [HistoryPoint] = []
    @Published private(set) var apps: [AppHistoryRow] = []
    @Published private(set) var events: [ProcessEvent] = []
    @Published private(set) var spikes: [SpikeRecord] = []
    @Published private(set) var stats = HistoryStats()
    @Published private(set) var agentInstalled = RecorderAgent.isInstalled
    @Published private(set) var agentRunning = false
    @Published private(set) var loaded = false

    private let store = HistoryStore()

    private struct Snapshot: Sendable {
        var points: [HistoryPoint] = []
        var apps: [AppHistoryRow] = []
        var events: [ProcessEvent] = []
        var spikes: [SpikeRecord] = []
        var stats = HistoryStats()
        var agentRunning = false
    }

    func refresh() async {
        guard let store else { loaded = true; return }
        let range = self.range, section = self.section
        let installed = RecorderAgent.isInstalled
        let snap = await Task.detached(priority: .userInitiated) { () -> Snapshot in
            var s = Snapshot()
            let now = Int64(Date().timeIntervalSince1970)
            let since = now - range.seconds
            switch section {
            case .graphs: s.points = store.series(since: since, until: now)
            case .apps: s.apps = store.appHistory(since: since)
            case .spikes: s.spikes = store.spikes(since: since)
            case .events: s.events = store.events(since: since)
            }
            s.stats = store.stats()
            s.agentRunning = installed && RecorderAgent.isRunning
            return s
        }.value
        // 取得中に期間や表示が変わっていたら捨てる
        guard range == self.range, section == self.section else { return }
        points = snap.points
        apps = snap.apps
        events = snap.events
        spikes = snap.spikes
        stats = snap.stats
        agentInstalled = installed
        agentRunning = snap.agentRunning
        loaded = true
    }

    func setAgent(enabled: Bool) -> String? {
        let error = enabled ? RecorderAgent.install() : RecorderAgent.uninstall()
        agentInstalled = RecorderAgent.isInstalled
        return error
    }

    func deleteAll() async {
        guard let store else { return }
        await Task.detached { store.deleteAll() }.value
        await refresh()
    }

    /// 記録の状態 (表示用)
    var status: (color: Color, text: String) {
        let age = stats.latest.map { Date().timeIntervalSince($0) } ?? .infinity
        if age < 20 {
            return agentInstalled
                ? (.green, "バックグラウンドで記録中")
                : (.yellow, "このアプリで記録中（アプリを閉じると停止）")
        }
        if agentInstalled && !agentRunning { return (.orange, "エージェントが停止しています") }
        return (.secondary, "記録していません")
    }
}

// MARK: - 履歴タブ

@MainActor
struct HistoryView: View {
    @EnvironmentObject private var m: Monitor
    let search: String

    @StateObject private var model = HistoryModel()
    @StateObject private var appSortBox = Box<[KeyPathComparator<AppHistoryRow>]>([KeyPathComparator(\.cpuSec, order: .reverse)])
    @StateObject private var eventSortBox = Box<[KeyPathComparator<ProcessEvent>]>([KeyPathComparator(\.ts, order: .reverse)])
    @StateObject private var confirmDeleteBox = Box<Bool>(false)

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm:ss"
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/M/d HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: model.range.rawValue + "-" + model.section.rawValue) {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        .confirmationDialog("すべての履歴を削除しますか？", isPresented: $confirmDeleteBox.value) {
            Button("削除", role: .destructive) { Task { await model.deleteAll() } }
        } message: {
            Text("記録したグラフ・アプリの履歴・ログはすべて消え、元に戻せません。")
        }
    }

    // MARK: ヘッダー

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("表示", selection: $model.section) {
                    ForEach(HistorySection.allCases) { s in Text(s.title).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 480)
                Spacer()
                Picker("期間", selection: $model.range) {
                    ForEach(HistoryRange.allCases) { r in Text(r.title).tag(r) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)
            }
            HStack(spacing: 10) {
                let st = model.status
                Circle().fill(st.color).frame(width: 8, height: 8)
                Text(st.text).font(.callout)
                if let latest = model.stats.latest {
                    Text("最終記録: \(Self.timeFormatter.string(from: latest))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let earliest = model.stats.earliest {
                    Text("\(Self.dayFormatter.string(from: earliest)) から")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("保存データ \(Fmt.bytes(model.stats.fileSize))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.agentInstalled ? "バックグラウンド記録を停止" : "バックグラウンドで記録する") {
                    toggleAgent()
                }
                .help("ログイン中は常に 5 秒ごとに記録します（LaunchAgent）")
                Menu {
                    Button("保存フォルダを Finder で表示") {
                        HistoryPaths.ensureDirectory()
                        NSWorkspace.shared.activateFileViewerSelecting([HistoryPaths.database])
                    }
                    Divider()
                    Button("すべての履歴を削除…", role: .destructive) { confirmDeleteBox.value = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            }
            if !model.agentInstalled {
                Text("いまはこのアプリを開いている間だけ記録します。閉じている間も記録するには「バックグラウンドで記録する」を押してください。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !RecorderAgent.isInApplications {
                Text("⚠️ このアプリが /Applications 以外から起動されています。アプリを移動するとバックグラウンド記録が止まるので、./build_app.sh --install でインストールしてから有効にしてください。")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func toggleAgent() {
        let enable = !model.agentInstalled
        if let error = model.setAgent(enabled: enable) {
            m.alert = AlertInfo(title: "バックグラウンド記録", message: error)
        }
        Task { await model.refresh() }
    }

    // MARK: 内容

    @ViewBuilder private var content: some View {
        switch model.section {
        case .graphs: graphs
        case .apps: appsTable
        case .spikes: spikesList
        case .events: eventsTable
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.tertiary)
            Text(model.loaded ? text : "読み込み中…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 推移グラフ

    @ViewBuilder private var graphs: some View {
        if model.points.isEmpty {
            emptyState("この期間の記録はまだありません。")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HistoryChart(title: "CPU", unit: .percent, points: model.points, hoverTs: $model.hoverTs,
                                 series: [HistorySeries(id: "CPU", color: Palette.cpu, key: \.cpu)])
                    HistoryChart(title: "メモリ", unit: .percent, points: model.points, hoverTs: $model.hoverTs,
                                 series: [HistorySeries(id: "メモリ", color: Palette.memory, key: \.mem)])
                    HistoryChart(title: "ディスク", unit: .bytesPerSec, points: model.points, hoverTs: $model.hoverTs,
                                 series: [HistorySeries(id: "読み取り", color: Palette.disk, key: \.diskR),
                                          HistorySeries(id: "書き込み", color: Palette.disk.opacity(0.45), key: \.diskW)])
                    HistoryChart(title: "ネットワーク", unit: .bitsPerSec, points: model.points, hoverTs: $model.hoverTs,
                                 series: [HistorySeries(id: "受信", color: Palette.network, key: \.netRx),
                                          HistorySeries(id: "送信", color: Palette.network.opacity(0.45), key: \.netTx)])
                    HistoryChart(title: "GPU", unit: .percent, points: model.points, hoverTs: $model.hoverTs,
                                 series: [HistorySeries(id: "GPU", color: Palette.gpu, key: \.gpu)])
                    Text("記録が途切れている時間（Mac のスリープ中など）は線が切れて表示されます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
    }

    // MARK: アプリの履歴

    private var filteredApps: [AppHistoryRow] {
        let q = search.lowercased()
        let rows = q.isEmpty ? model.apps : model.apps.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) }
        return rows.sorted(using: appSortBox.value)
    }

    @ViewBuilder private var appsTable: some View {
        if model.apps.isEmpty {
            emptyState("この期間のアプリの記録はまだありません。")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Table(filteredApps, sortOrder: $appSortBox.value) {
                    TableColumn("名前", value: \.name) { a in
                        HStack(spacing: 6) {
                            Image(nsImage: IconCache.shared.icon(path: a.path,
                                                                 bundlePath: a.path.hasSuffix(".app") ? a.path : nil))
                                .resizable().frame(width: 16, height: 16)
                            Text(a.name).lineLimit(1)
                        }
                    }
                    .width(min: 200, ideal: 280)
                    TableColumn("CPU 時間", value: \.cpuSec) { a in
                        Text(Fmt.cpuTime(a.cpuSec)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    TableColumn("ディスク", value: \.diskBytes) { a in
                        Text(Fmt.bytes(a.diskBytes)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    TableColumn("最大メモリ", value: \.memPeak) { a in
                        Text(Fmt.bytes(a.memPeak)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    TableColumn("動作していた時間", value: \.activeBuckets) { a in
                        Text(Self.minutesText(a.activeMinutes)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                Text("10 分単位で集計しています。ヘルパー プロセスは所属するアプリにまとめています。他ユーザー (root) のプロセスのディスク量は取得できません。")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    private static func minutesText(_ m: Int) -> String {
        if m < 60 { return "約 \(m) 分" }
        return "約 \(m / 60) 時間 \(m % 60) 分"
    }

    // MARK: 高負荷の記録

    @ViewBuilder private var spikesList: some View {
        if model.spikes.isEmpty {
            emptyState("この期間に高負荷の記録はありません。\n（CPU \(Int(HistoryRecorder.cpuSpikeThreshold))% 以上 / メモリ \(Int(HistoryRecorder.memSpikeThreshold))% 以上で記録）")
        } else {
            List {
                Section {
                    ForEach(model.spikes) { s in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: s.kind == "cpu" ? "cpu" : "memorychip")
                                .font(.title2)
                                .foregroundStyle(s.kind == "cpu" ? Palette.cpu : Palette.memory)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(s.kind == "cpu" ? "CPU \(Int(s.value))%" : "メモリ \(Int(s.value))%")
                                        .font(.headline)
                                    Text(Self.timeFormatter.string(from: s.date))
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(Array(s.top.enumerated()), id: \.offset) { item in
                                    Text("\(item.offset + 1). \(item.element)")
                                        .font(.callout.monospacedDigit())
                                        .foregroundStyle(item.offset == 0 ? Color.primary : Color.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text("CPU \(Int(HistoryRecorder.cpuSpikeThreshold))% 以上、またはメモリ \(Int(HistoryRecorder.memSpikeThreshold))% 以上になったときに、その時点の上位 5 プロセスを記録します（同じ種類は 2 分に 1 回まで）。")
                }
            }
        }
    }

    // MARK: 起動・終了ログ

    private var filteredEvents: [ProcessEvent] {
        let q = search.lowercased()
        let rows = q.isEmpty ? model.events : model.events.filter {
            $0.name.lowercased().contains(q) || String($0.pid) == q
                || $0.user.lowercased().contains(q) || $0.path.lowercased().contains(q)
        }
        return rows.sorted(using: eventSortBox.value)
    }

    @ViewBuilder private var eventsTable: some View {
        if model.events.isEmpty {
            emptyState("この期間の起動・終了の記録はまだありません。")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Table(filteredEvents, sortOrder: $eventSortBox.value) {
                    TableColumn("時刻", value: \.ts) { e in
                        Text(Self.timeFormatter.string(from: e.date)).monospacedDigit()
                    }
                    .width(min: 100, ideal: 120)
                    TableColumn("種類", value: \.kindText) { e in
                        Label(e.kindText, systemImage: e.started ? "play.circle.fill" : "stop.circle")
                            .foregroundStyle(e.started ? Color.green : Color.secondary)
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("名前", value: \.name) { e in
                        HStack(spacing: 6) {
                            Image(nsImage: IconCache.shared.icon(path: e.path, bundlePath: nil))
                                .resizable().frame(width: 16, height: 16)
                            Text(e.name).lineLimit(1)
                        }
                    }
                    .width(min: 160, ideal: 220)
                    TableColumn("PID", value: \.pid) { e in Text(String(e.pid)).monospacedDigit() }
                        .width(min: 45, ideal: 60)
                    TableColumn("ユーザー", value: \.user).width(min: 60, ideal: 90)
                    TableColumn("パス", value: \.path) { e in
                        Text(e.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Text("5 秒ごとの比較で記録しているため、5 秒未満で終了したプロセスは記録されないことがあります。最新 5,000 件まで表示します。")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }
}

// MARK: - 推移グラフ 1 枚

struct HistorySeries: Identifiable {
    let id: String
    let color: Color
    let key: KeyPath<HistoryPoint, Double>
}

enum HistoryUnit {
    case percent, bytesPerSec, bitsPerSec

    func format(_ v: Double) -> String {
        switch self {
        case .percent: return String(format: "%.0f%%", v)
        case .bytesPerSec: return Fmt.rate(v)
        case .bitsPerSec: return Fmt.bits(v)
        }
    }
}

@MainActor
struct HistoryChart: View {
    let title: String
    let unit: HistoryUnit
    let points: [HistoryPoint]
    @Binding var hoverTs: Int64?
    let series: [HistorySeries]

    private static let hoverFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    private var hovered: HistoryPoint? {
        guard let ts = hoverTs, !points.isEmpty else { return nil }
        return points.min { abs($0.ts - ts) < abs($1.ts - ts) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.headline)
                ForEach(series) { s in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1).fill(s.color).frame(width: 12, height: 3)
                        Text(s.id).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let h = hovered {
                    Text(Self.hoverFormatter.string(from: h.date)).font(.caption).foregroundStyle(.secondary)
                    ForEach(series) { s in
                        Text("\(s.id) \(unit.format(h[keyPath: s.key]))")
                            .font(.caption.monospacedDigit())
                    }
                } else {
                    ForEach(series) { s in
                        let values = points.map { $0[keyPath: s.key] }
                        let avg = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
                        Text("\(s.id) 平均 \(unit.format(avg)) / 最大 \(unit.format(values.max() ?? 0))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            chart.frame(height: 140)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(series) { s in
                ForEach(points) { p in
                    LineMark(
                        x: .value("時刻", p.date),
                        y: .value(s.id, p[keyPath: s.key]),
                        series: .value("系列", "\(s.id)-\(p.segment)")
                    )
                    .foregroundStyle(s.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                }
            }
            if let h = hovered {
                RuleMark(x: .value("時刻", h.date))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(unit.format(v)).font(.caption2)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geo[plot].origin.x
                            if let date = proxy.value(atX: x, as: Date.self) {
                                hoverTs = Int64(date.timeIntervalSince1970)
                            }
                        case .ended:
                            hoverTs = nil
                        }
                    }
            }
        }
    }

    private var yDomain: ClosedRange<Double> {
        switch unit {
        case .percent:
            return 0...100
        case .bytesPerSec, .bitsPerSec:
            let maxV = series.flatMap { s in points.map { $0[keyPath: s.key] } }.max() ?? 0
            return 0...max(maxV * 1.1, unit == .bitsPerSec ? 1000 : 1024)
        }
    }
}
