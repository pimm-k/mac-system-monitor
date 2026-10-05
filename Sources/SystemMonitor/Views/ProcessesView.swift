import SwiftUI
import AppKit

/// プロセス タブの 1 行
struct ProcRow: Identifiable, Hashable {
    enum Kind: Hashable { case header, app, child, background }
    var id: String
    var kind: Kind
    var pid: pid_t
    var name: String
    var path: String
    var bundlePath: String?
    var status: String
    var cpu: Double
    var memory: UInt64
    var disk: Double
    var childCount: Int
}

@MainActor
struct ProcessesView: View {
    @Environment(\.uiScale) private var ui
    @EnvironmentObject private var m: Monitor
    let search: String

    @StateObject private var selectionBox = Box<Set<String>>([])

    private var selection: Set<String> {

        get { selectionBox.value }

        nonmutating set { selectionBox.value = newValue }

    }
    @StateObject private var sortOrderBox = Box<[KeyPathComparator<ProcRow>]>([KeyPathComparator(\.cpu, order: .reverse)])
    private var sortOrder: [KeyPathComparator<ProcRow>] {
        get { sortOrderBox.value }
        nonmutating set { sortOrderBox.value = newValue }
    }
    @StateObject private var expandedBox = Box<Set<pid_t>>([])
    private var expanded: Set<pid_t> {
        get { expandedBox.value }
        nonmutating set { expandedBox.value = newValue }
    }
    @StateObject private var confirmForceBox = Box<Bool>(false)
    /// 右側の詳細パネル
    @StateObject private var detail = ProcessDetailModel()
    @StateObject private var showPanelBox = Box<Bool>(UserDefaults.standard.object(forKey: "processDetailPanel") as? Bool ?? true)
    private var showPanel: Bool {
        get { showPanelBox.value }
        nonmutating set {
            showPanelBox.value = newValue
            UserDefaults.standard.set(newValue, forKey: "processDetailPanel")
            if newValue { updateDetail() }
        }
    }
    private var confirmForce: Bool {
        get { confirmForceBox.value }
        nonmutating set { confirmForceBox.value = newValue }
    }

    var body: some View {
        let rows = buildRows()
        let cpuTitle = "CPU  \(Int(m.system.cpu.total.rounded()))%"
        let memTitle = L("メモリ  %@%%", "\(Int(m.system.mem.percent.rounded()))")
        let diskTitle = L("ディスク  %@%%", "\(Int(m.system.disk.active.rounded()))")
        let total = Double(max(m.system.mem.total, 1))

        HSplitView {
        Table(rows, selection: $selectionBox.value, sortOrder: $sortOrderBox.value) {
            TableColumn(L("名前"), value: \.name) { row in
                NameCell(row: row, expanded: expanded.contains(row.pid)) { toggle(row.pid) }
            }
            .width(min: 240 * ui, ideal: 340 * ui)

            TableColumn(L("状態"), value: \.status) { row in
                Text(row.status).foregroundStyle(.secondary)
            }
            .width(min: 40 * ui, ideal: 60 * ui)

            TableColumn(cpuTitle, value: \.cpu) { row in
                HeatCell(text: row.kind == .header ? "" : Fmt.percent(row.cpu), level: row.cpu / 40)
            }
            .width(min: 80 * ui, ideal: 95 * ui)

            TableColumn(memTitle, value: \.memory) { row in
                HeatCell(text: row.kind == .header ? "" : Fmt.bytes(row.memory),
                         level: Double(row.memory) / total * 8)
            }
            .width(min: 90 * ui, ideal: 110 * ui)

            TableColumn(diskTitle, value: \.disk) { row in
                HeatCell(text: row.kind == .header ? "" : String(format: L("%.1f MB/秒"), row.disk / 1_048_576),
                         level: row.disk / 20_000_000)
            }
            .width(min: 90 * ui, ideal: 110 * ui)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let targets = rows.filter { ids.contains($0.id) && $0.kind != .header }
            if !targets.isEmpty {
                Button(L("タスクの終了")) { end(targets, force: false) }
                Button(L("強制終了")) { selection = ids; confirmForce = true }
                Divider()
                if let first = targets.first {
                    Button(L("ファイルの場所を開く")) { m.revealInFinder(path: first.bundlePath ?? first.path) }
                    Button(L("詳細に移動")) {
                        m.focusPid = first.pid
                        m.tab = .details
                    }
                    Button(L("PID をコピー")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(String(first.pid), forType: .string)
                    }
                    if !showPanel {
                        Button(L("詳細パネルを表示")) { showPanel = true }
                    }
                }
            }
        } primaryAction: { ids in
            for r in rows where ids.contains(r.id) && r.childCount > 0 { toggle(r.pid) }
        }
        .onDeleteCommand { end(selectedRows(rows), force: false) }
        .confirmationDialog(L("選択したプロセスを強制終了しますか？"), isPresented: $confirmForceBox.value) {
            Button(L("強制終了"), role: .destructive) { end(selectedRows(rows), force: true) }
        } message: {
            Text(L("保存されていないデータは失われます。"))
        }
        .frame(minWidth: 420 * ui)

        if showPanel {
            ProcessDetailPanel(model: detail, isApp: selectedIsApp, onClose: { showPanel = false })
                .frame(minWidth: 320 * ui, idealWidth: 420 * ui, maxWidth: 680 * ui)
        }
        }
        .onChange(of: selectionBox.value) { updateDetail() }
        .onAppear { updateDetail() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { m.runNewTask() } label: {
                    Label(L("新しいタスクを実行する"), systemImage: "plus.app")
                }
                .help(L("新しいタスクを実行する"))
                Button { end(selectedRows(rows), force: false) } label: {
                    Label(L("タスクを終了する"), systemImage: "xmark.circle")
                }
                .help(L("タスクを終了する"))
                .disabled(selectedRows(rows).isEmpty)
                Button { showPanel.toggle() } label: {
                    Label(L("詳細パネル"), systemImage: "sidebar.right")
                }
                .help(showPanel ? L("詳細パネルを隠す") : L("詳細パネルを表示"))
            }
        }
    }

    // MARK: - 詳細パネル

    /// 選択中の行 (1 行だけのとき) のプロセス
    private var selectedPid: pid_t? {
        guard selection.count == 1, let id = selection.first,
              id.hasPrefix("p") || id.hasPrefix("c"), let pid = pid_t(id.dropFirst()) else { return nil }
        return pid
    }

    private var selectedIsApp: Bool {
        guard let id = selection.first, id.hasPrefix("p"), let pid = selectedPid else { return false }
        return m.processes.first { $0.pid == pid }?.isRegularApp ?? false
    }

    private func updateDetail() {
        guard showPanel else { return }
        let pid = selectedPid
        detail.select(pid.flatMap { p in m.processes.first { $0.pid == p } })
    }

    // MARK: - 行の組み立て

    private func buildRows() -> [ProcRow] {
        let procs = m.processes
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let apps = procs.filter { $0.isRegularApp }
        let appPids = Set(apps.map(\.pid))
        let bundles: [(pid_t, String)] = apps.compactMap { a in a.bundlePath.map { (a.pid, $0 + "/") } }

        // アプリ配下のヘルパー/子プロセスをまとめる
        var children: [pid_t: [ProcItem]] = [:]
        var background: [ProcItem] = []
        for p in procs where !p.isRegularApp {
            if let owner = bundles.first(where: { p.path.hasPrefix($0.1) })?.0 {
                children[owner, default: []].append(p)
            } else if appPids.contains(p.ppid) {
                children[p.ppid, default: []].append(p)
            } else {
                background.append(p)
            }
        }

        func matches(_ p: ProcItem) -> Bool {
            q.isEmpty || p.name.lowercased().contains(q) || String(p.pid) == q || p.user.lowercased().contains(q)
        }
        func row(_ p: ProcItem, kind: ProcRow.Kind, kids: [ProcItem] = []) -> ProcRow {
            ProcRow(id: (kind == .child ? "c" : "p") + String(p.pid),
                    kind: kind, pid: p.pid, name: p.name, path: p.path, bundlePath: p.bundlePath,
                    status: p.status,
                    cpu: kids.reduce(p.cpu) { $0 + $1.cpu },
                    memory: kids.reduce(p.memory) { $0 + $1.memory },
                    disk: kids.reduce(p.disk) { $0 + $1.disk },
                    childCount: kids.count)
        }

        var appRows: [ProcRow] = []
        for a in apps {
            let kids = children[a.pid] ?? []
            guard matches(a) || kids.contains(where: matches) else { continue }
            appRows.append(row(a, kind: .app, kids: kids))
        }
        appRows.sort(using: sortOrder)

        let bgRows = background.filter(matches).map { row($0, kind: .background) }.sorted(using: sortOrder)

        var out: [ProcRow] = []
        out.append(header("h-apps", L("アプリ (%@)", "\(appRows.count)")))
        for r in appRows {
            out.append(r)
            if expanded.contains(r.pid) || !q.isEmpty {
                let kids = (children[r.pid] ?? []).map { row($0, kind: .child) }.sorted(using: sortOrder)
                out.append(contentsOf: kids)
            }
        }
        out.append(header("h-bg", L("バックグラウンド プロセス (%@)", "\(bgRows.count)")))
        out.append(contentsOf: bgRows)
        return out
    }

    private func header(_ id: String, _ title: String) -> ProcRow {
        ProcRow(id: id, kind: .header, pid: -1, name: title, path: "", bundlePath: nil,
                status: "", cpu: 0, memory: 0, disk: 0, childCount: 0)
    }

    private func toggle(_ pid: pid_t) {
        if expanded.contains(pid) { expanded.remove(pid) } else { expanded.insert(pid) }
    }

    private func selectedRows(_ rows: [ProcRow]) -> [ProcRow] {
        rows.filter { selection.contains($0.id) && $0.kind != .header }
    }

    private func end(_ targets: [ProcRow], force: Bool) {
        let appPids = targets.filter { $0.kind == .app }.map(\.pid)
        let others = targets.filter { $0.kind != .app }.map(\.pid)
        if !appPids.isEmpty { m.endTask(pids: appPids, force: force, preferApp: true) }
        if !others.isEmpty { m.endTask(pids: others, force: force, preferApp: false) }
        selection.removeAll()
    }
}

@MainActor
private struct NameCell: View {
    @Environment(\.uiScale) private var ui
    let row: ProcRow
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        if row.kind == .header {
            Text(row.name).scaledFont(.headline).padding(.top, 6)
        } else {
            HStack(spacing: 6) {
                if row.kind == .child { Spacer().frame(width: 16 * ui) }
                if row.childCount > 0 {
                    Button(action: toggle) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .scaledFont(size: 9, weight: .bold)
                            .frame(width: 12 * ui)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 12 * ui)
                }
                Image(nsImage: IconCache.shared.icon(path: row.path, bundlePath: row.bundlePath))
                    .resizable()
                    .frame(width: 16 * ui, height: 16 * ui)
                Text(row.name).lineLimit(1)
                if row.childCount > 0 {
                    Text("(\(row.childCount + 1))").foregroundStyle(.secondary)
                }
            }
        }
    }
}
