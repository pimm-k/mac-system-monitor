import SwiftUI
import AppKit
import Charts

// MARK: - 期間・表示の種類

enum HistoryRange: String, CaseIterable, Identifiable {
    case h1, h6, d1, d7, d30
    var id: String { rawValue }
    var title: String {
        switch self {
        case .h1: return L("1時間")
        case .h6: return L("6時間")
        case .d1: return L("24時間")
        case .d7: return L("7日")
        case .d30: return L("30日")
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
    @Published private(set) var netAlerts: [NetAlertRecord] = []
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
        var netAlerts: [NetAlertRecord] = []
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
            case .network: s.netAlerts = store.netAlerts(since: since)
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
        netAlerts = snap.netAlerts
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

    func delete(_ kinds: Set<HistoryDataKind>) async {
        guard let store, !kinds.isEmpty else { return }
        await Task.detached { store.delete(kinds) }.value
        await refresh()
    }

    func counts() async -> [HistoryDataKind: Int] {
        guard let store else { return [:] }
        return await Task.detached { store.counts() }.value
    }

    /// 記録の状態 (表示用)
    var status: (color: Color, text: String) {
        let age = stats.latest.map { Date().timeIntervalSince($0) } ?? .infinity
        if age < 20 {
            return agentInstalled
                ? (.green, L("バックグラウンドで記録中"))
                : (.yellow, L("このアプリで記録中（アプリを閉じると停止）"))
        }
        if agentInstalled && !agentRunning { return (.orange, L("エージェントが停止しています")) }
        return (.secondary, L("記録していません"))
    }
}

// MARK: - 履歴タブ

@MainActor
struct HistoryView: View {
    @Environment(\.uiScale) private var ui
    @EnvironmentObject private var m: Monitor
    let search: String

    @StateObject private var model = HistoryModel()
    @StateObject private var appSortBox = Box<[KeyPathComparator<AppHistoryRow>]>([KeyPathComparator(\.cpuSec, order: .reverse)])
    @StateObject private var eventSortBox = Box<[KeyPathComparator<ProcessEvent>]>([KeyPathComparator(\.ts, order: .reverse)])
    @StateObject private var confirmDeleteBox = Box<Bool>(false)
    @StateObject private var netEnabledBox = Box<Bool>(NetAlertSettings.enabled)
    @StateObject private var netUploadBox = Box<Bool>(NetAlertSettings.upload)
    @StateObject private var ignoredBox = Box<Set<String>>(NetAlertSettings.ignored)

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
        .sheet(isPresented: $confirmDeleteBox.value) {
            DeleteHistorySheet(model: model)
        }
    }

    // MARK: ヘッダー

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker(L("表示"), selection: $model.section) {
                    ForEach(HistorySection.allCases) { s in Text(s.title).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 600 * ui)
                Spacer()
                Picker(L("期間"), selection: $model.range) {
                    ForEach(HistoryRange.allCases) { r in Text(r.title).tag(r) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300 * ui)
            }
            HStack(spacing: 10) {
                let st = model.status
                Circle().fill(st.color).frame(width: 8 * ui, height: 8 * ui)
                Text(st.text).scaledFont(.callout)
                if let latest = model.stats.latest {
                    Text(L("最終記録: %@", "\(Self.timeFormatter.string(from: latest))"))
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
                if let earliest = model.stats.earliest {
                    Text(L("%@ から", "\(Self.dayFormatter.string(from: earliest))"))
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
                Text(L("保存データ %@", "\(Fmt.bytes(model.stats.fileSize))"))
                    .scaledFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.agentInstalled ? L("バックグラウンド記録を停止") : L("バックグラウンドで記録する")) {
                    toggleAgent()
                }
                .help(L("ログイン中は常に 5 秒ごとに記録します（LaunchAgent）"))
                Menu {
                    Button(L("保存フォルダを Finder で表示")) {
                        HistoryPaths.ensureDirectory()
                        NSWorkspace.shared.activateFileViewerSelecting([HistoryPaths.database])
                    }
                    Divider()
                    Button(L("履歴を削除…"), role: .destructive) { confirmDeleteBox.value = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            }
            if !model.agentInstalled {
                Text(L("いまはこのアプリを開いている間だけ記録します。閉じている間も記録するには「バックグラウンドで記録する」を押してください。"))
                    .scaledFont(.caption).foregroundStyle(.secondary)
            } else if !RecorderAgent.isInApplications {
                Text(L("⚠️ このアプリが /Applications 以外から起動されています。アプリを移動するとバックグラウンド記録が止まるので、./build_app.sh --install でインストールしてから有効にしてください。"))
                    .scaledFont(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func toggleAgent() {
        let enable = !model.agentInstalled
        if let error = model.setAgent(enabled: enable) {
            m.alert = AlertInfo(title: L("バックグラウンド記録"), message: error)
        }
        Task { await model.refresh() }
    }

    // MARK: 内容

    @ViewBuilder private var content: some View {
        switch model.section {
        case .graphs: graphs
        case .apps: appsTable
        case .spikes: spikesList
        case .network: networkList
        case .events: eventsTable
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").scaledFont(.largeTitle).foregroundStyle(.tertiary)
            Text(model.loaded ? text : L("読み込み中…")).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 推移グラフ

    @ViewBuilder private var graphs: some View {
        if model.points.isEmpty {
            emptyState(L("この期間の記録はまだありません。"))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HistoryChart(title: "CPU", unit: .percent, points: model.points, hoverTs: $model.hoverTs,
                                 series: [HistorySeries(id: "CPU", color: Palette.cpu, key: \.cpu)])
                    HistoryChart(title: L("メモリ"), unit: .percent, points: model.points, hoverTs: $model.hoverTs,
                                 series: [HistorySeries(id: L("メモリ"), color: Palette.memory, key: \.mem)])
                    HistoryChart(title: L("ディスク"), unit: .bytesPerSec, points: model.points, hoverTs: $model.hoverTs,
                                 series: [HistorySeries(id: L("読み取り"), color: Palette.disk, key: \.diskR),
                                          HistorySeries(id: L("書き込み"), color: Palette.disk.opacity(0.45), key: \.diskW)])
                    HistoryChart(title: L("ネットワーク"), unit: .bitsPerSec, points: model.points, hoverTs: $model.hoverTs,
                                 series: [HistorySeries(id: L("受信"), color: Palette.network, key: \.netRx),
                                          HistorySeries(id: L("送信"), color: Palette.network.opacity(0.45), key: \.netTx)])
                    HistoryChart(title: "GPU", unit: .percent, points: model.points, hoverTs: $model.hoverTs,
                                 series: [HistorySeries(id: "GPU", color: Palette.gpu, key: \.gpu)])
                    Text(L("記録が途切れている時間（Mac のスリープ中など）は線が切れて表示されます。"))
                        .scaledFont(.caption).foregroundStyle(.secondary)
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
            emptyState(L("この期間のアプリの記録はまだありません。"))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Table(filteredApps, sortOrder: $appSortBox.value) {
                    TableColumn(L("名前"), value: \.name) { a in
                        HStack(spacing: 6) {
                            Image(nsImage: IconCache.shared.icon(path: a.path,
                                                                 bundlePath: a.path.hasSuffix(".app") ? a.path : nil))
                                .resizable().frame(width: 16 * ui, height: 16 * ui)
                            Text(a.name).lineLimit(1)
                        }
                    }
                    .width(min: 200 * ui, ideal: 280 * ui)
                    TableColumn(L("CPU 時間"), value: \.cpuSec) { a in
                        Text(Fmt.cpuTime(a.cpuSec)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    TableColumn(L("ディスク"), value: \.diskBytes) { a in
                        Text(Fmt.bytes(a.diskBytes)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    TableColumn(L("最大メモリ"), value: \.memPeak) { a in
                        Text(Fmt.bytes(a.memPeak)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    TableColumn(L("動作していた時間"), value: \.activeBuckets) { a in
                        Text(Self.minutesText(a.activeMinutes)).monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                Text(L("10 分単位で集計しています。ヘルパー プロセスは所属するアプリにまとめています。他ユーザー (root) のプロセスのディスク量は取得できません。"))
                    .scaledFont(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    private static func minutesText(_ m: Int) -> String {
        if m < 60 { return L("約 %@ 分", "\(m)") }
        return L("約 %@ 時間 %@ 分", "\(m / 60)", "\(m % 60)")
    }

    // MARK: 高負荷の記録

    @ViewBuilder private var spikesList: some View {
        if model.spikes.isEmpty {
            emptyState(L("この期間に高負荷の記録はありません。\n（CPU %@%% 以上 / メモリ %@%% 以上で記録）", "\(Int(HistoryRecorder.cpuSpikeThreshold))", "\(Int(HistoryRecorder.memSpikeThreshold))"))
        } else {
            List {
                Section {
                    ForEach(model.spikes) { s in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: s.kind == "cpu" ? "cpu" : "memorychip")
                                .scaledFont(.title2)
                                .foregroundStyle(s.kind == "cpu" ? Palette.cpu : Palette.memory)
                                .frame(width: 28 * ui)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(s.kind == "cpu" ? "CPU \(Int(s.value))%" : L("メモリ %@%%", "\(Int(s.value))"))
                                        .scaledFont(.headline)
                                    Text(Self.timeFormatter.string(from: s.date))
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(Array(s.top.enumerated()), id: \.offset) { item in
                                    Text("\(item.offset + 1). \(item.element)")
                                        .scaledFont(.callout, mono: true)
                                        .foregroundStyle(item.offset == 0 ? Color.primary : Color.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text(L("CPU %@%% 以上、またはメモリ %@%% 以上になったときに、その時点の上位 5 プロセスを記録します（同じ種類は 2 分に 1 回まで）。", "\(Int(HistoryRecorder.cpuSpikeThreshold))", "\(Int(HistoryRecorder.memSpikeThreshold))"))
                }
            }
        }
    }

    // MARK: 通信の警告

    private var filteredNetAlerts: [NetAlertRecord] {
        let q = search.lowercased()
        guard !q.isEmpty else { return model.netAlerts }
        return model.netAlerts.filter {
            $0.name.lowercased().contains(q) || String($0.pid) == q
                || $0.path.lowercased().contains(q) || $0.remote.lowercased().contains(q)
        }
    }

    private var netSettings: some View {
        HStack(spacing: 16) {
            Toggle(L("怪しい通信を通知する"), isOn: Binding(
                get: { netEnabledBox.value },
                set: { v in
                    netEnabledBox.value = v
                    NetAlertSettings.enabled = v
                    if v { Notifier.requestAuthorization() }
                }))
            Toggle(L("大量の送信も通知する"), isOn: Binding(
                get: { netUploadBox.value },
                set: { v in netUploadBox.value = v; NetAlertSettings.upload = v }))
                .disabled(!netEnabledBox.value)
            Spacer()
            if !ignoredBox.value.isEmpty {
                Button(L("通知しない設定を解除 (%@ 件)", "\(ignoredBox.value.count)")) {
                    ignoredBox.value = []
                    NetAlertSettings.ignored = []
                }
            }
            Button(L("通知の設定…")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var netFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(NetRule.allCases, id: \.self) { r in
                Text(L("・%@：%@", "\(r.title)", "\(r.explanation)"))
            }
            Text(L("あなたのユーザーで動いているプロセスを 15 秒ごとに確認します（root のプロセスは対象外）。目安の判定のため、正常なアプリが通知されることもあります。同じ内容は 6 時間に 1 回まで通知します。"))
        }
        .scaledFont(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var networkList: some View {
        VStack(spacing: 0) {
            netSettings
            Divider()
            if filteredNetAlerts.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.shield").scaledFont(.largeTitle).foregroundStyle(.green)
                    Text(model.loaded ? (netEnabledBox.value ? L("この期間に怪しい通信は見つかっていません。") : L("怪しい通信の通知はオフです。"))
                                      : L("読み込み中…"))
                        .foregroundStyle(.secondary)
                    netFooter.frame(maxWidth: 640 * ui)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                List {
                    Section {
                        ForEach(filteredNetAlerts) { a in netAlertRow(a) }
                    } footer: {
                        netFooter
                    }
                }
            }
        }
    }

    private func netAlertRow(_ a: NetAlertRecord) -> some View {
        let rule = a.ruleValue
        let ignoreKey = NetAlertSettings.ignoreKey(rule: a.rule, path: a.path)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: rule?.icon ?? "exclamationmark.triangle")
                .scaledFont(.title2)
                .foregroundStyle(.orange)
                .frame(width: 28 * ui)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(rule?.title ?? a.rule).scaledFont(.headline)
                    Text(Self.timeFormatter.string(from: a.date)).foregroundStyle(.secondary)
                }
                if !a.path.isEmpty {
                    HStack(spacing: 6) {
                        Image(nsImage: IconCache.shared.icon(path: a.path, bundlePath: nil))
                            .resizable().frame(width: 16 * ui, height: 16 * ui)
                        Text("\(a.name)  (PID \(a.pid))")
                        if !a.remote.isEmpty {
                            Text("→ \(a.remote)").scaledFont(.callout, mono: true)
                        }
                    }
                    Text(a.path).scaledFont(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Text(a.detail).scaledFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if !a.path.isEmpty {
                    HStack(spacing: 12) {
                        Button(L("Finder で表示")) { m.revealInFinder(path: a.path) }
                        if ignoredBox.value.contains(ignoreKey) {
                            Text(L("今後は通知しません")).foregroundStyle(.secondary)
                        } else {
                            Button(L("このプログラムのこの種類は今後通知しない")) {
                                ignoredBox.value.insert(ignoreKey)
                                NetAlertSettings.ignored = ignoredBox.value
                            }
                        }
                    }
                    .buttonStyle(.link)
                    .scaledFont(.caption)
                }
            }
        }
        .padding(.vertical, 4)
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
            emptyState(L("この期間の起動・終了の記録はまだありません。"))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Table(filteredEvents, sortOrder: $eventSortBox.value) {
                    TableColumn(L("時刻"), value: \.ts) { e in
                        Text(Self.timeFormatter.string(from: e.date)).monospacedDigit()
                    }
                    .width(min: 100 * ui, ideal: 120 * ui)
                    TableColumn(L("種類"), value: \.kindText) { e in
                        Label(e.kindText, systemImage: e.started ? "play.circle.fill" : "stop.circle")
                            .foregroundStyle(e.started ? Color.green : Color.secondary)
                    }
                    .width(min: 60 * ui, ideal: 70 * ui)
                    TableColumn(L("名前"), value: \.name) { e in
                        HStack(spacing: 6) {
                            Image(nsImage: IconCache.shared.icon(path: e.path, bundlePath: nil))
                                .resizable().frame(width: 16 * ui, height: 16 * ui)
                            Text(e.name).lineLimit(1)
                        }
                    }
                    .width(min: 160 * ui, ideal: 220 * ui)
                    TableColumn("PID", value: \.pid) { e in Text(String(e.pid)).monospacedDigit() }
                        .width(min: 45 * ui, ideal: 60 * ui)
                    TableColumn(L("ユーザー"), value: \.user).width(min: 60 * ui, ideal: 90 * ui)
                    TableColumn(L("パス"), value: \.path) { e in
                        Text(e.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Text(L("5 秒ごとの比較で記録しているため、5 秒未満で終了したプロセスは記録されないことがあります。最新 5,000 件まで表示します。"))
                    .scaledFont(.caption).foregroundStyle(.secondary)
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
    @Environment(\.uiScale) private var ui
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
                Text(title).scaledFont(.headline)
                ForEach(series) { s in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1).fill(s.color).frame(width: 12 * ui, height: 3 * ui)
                        Text(s.id).scaledFont(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let h = hovered {
                    Text(Self.hoverFormatter.string(from: h.date)).scaledFont(.caption).foregroundStyle(.secondary)
                    ForEach(series) { s in
                        Text("\(s.id) \(unit.format(h[keyPath: s.key]))")
                            .scaledFont(.caption, mono: true)
                    }
                } else {
                    ForEach(series) { s in
                        let values = points.map { $0[keyPath: s.key] }
                        let avg = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
                        Text(L("%@ 平均 %@ / 最大 %@", "\(s.id)", "\(unit.format(avg))", "\(unit.format(values.max() ?? 0))"))
                            .scaledFont(.caption, mono: true)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            chart.frame(height: 140 * ui)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(series) { s in
                ForEach(points) { p in
                    LineMark(
                        x: .value(L("時刻"), p.date),
                        y: .value(s.id, p[keyPath: s.key]),
                        series: .value(L("系列"), "\(s.id)-\(p.segment)")
                    )
                    .foregroundStyle(s.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.4))
                }
            }
            if let h = hovered {
                RuleMark(x: .value(L("時刻"), h.date))
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
                        Text(unit.format(v)).scaledFont(.caption2)
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

// MARK: - 履歴の削除 (種類を選んで削除)

@MainActor
private struct DeleteHistorySheet: View {
    @ObservedObject var model: HistoryModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var selectedBox = Box<Set<HistoryDataKind>>([])
    @StateObject private var countsBox = Box<[HistoryDataKind: Int]?>(nil)
    @StateObject private var confirmBox = Box<Bool>(false)
    @StateObject private var deletingBox = Box<Bool>(false)

    private var selected: Set<HistoryDataKind> { selectedBox.value }
    private var allSelected: Bool { selected.count == HistoryDataKind.allCases.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("削除する履歴を選んでください")).font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(HistoryDataKind.allCases) { k in
                    Toggle(isOn: Binding(
                        get: { selectedBox.value.contains(k) },
                        set: { on in
                            if on { selectedBox.value.insert(k) } else { selectedBox.value.remove(k) }
                        })) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(k.title)
                                Text(countText(k)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Text(k.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            Text(L("削除した履歴は元に戻せません。"))
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button(allSelected ? L("選択をすべて解除") : L("すべて選択")) {
                    selectedBox.value = allSelected ? [] : Set(HistoryDataKind.allCases)
                }
                Spacer()
                if deletingBox.value { ProgressView().controlSize(.small) }
                Button(L("キャンセル")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("削除…"), role: .destructive) { confirmBox.value = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || deletingBox.value)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { countsBox.value = await model.counts() }
        .confirmationDialog(confirmTitle, isPresented: $confirmBox.value) {
            Button(L("削除"), role: .destructive) {
                let kinds = selected
                deletingBox.value = true
                Task {
                    await model.delete(kinds)
                    deletingBox.value = false
                    dismiss()
                }
            }
        } message: {
            Text(HistoryDataKind.allCases.filter { selected.contains($0) }.map { L("・") + $0.title }.joined(separator: "\n")
                 + L("\n\nこの操作は元に戻せません。"))
        }
    }

    private var confirmTitle: String {
        allSelected ? L("すべての履歴を削除しますか？") : L("選んだ %@ 種類の履歴を削除しますか？", "\(selected.count)")
    }

    private func countText(_ k: HistoryDataKind) -> String {
        guard let c = countsBox.value?[k] else { return "" }
        return k == .graphs ? L("（%@ 分ぶん）", "\(c)") : L("（%@ 件）", "\(c)")
    }
}
