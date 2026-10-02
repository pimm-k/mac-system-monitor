import SwiftUI
import AppKit

@MainActor
struct DetailsView: View {
    @EnvironmentObject private var m: Monitor
    let search: String

    @StateObject private var selectionBox = Box<Set<pid_t>>([])

    private var selection: Set<pid_t> {

        get { selectionBox.value }

        nonmutating set { selectionBox.value = newValue }

    }
    @StateObject private var sortOrderBox = Box<[KeyPathComparator<ProcItem>]>([KeyPathComparator(\.name)])
    private var sortOrder: [KeyPathComparator<ProcItem>] {
        get { sortOrderBox.value }
        nonmutating set { sortOrderBox.value = newValue }
    }
    @StateObject private var confirmForceBox = Box<Bool>(false)
    private var confirmForce: Bool {
        get { confirmForceBox.value }
        nonmutating set { confirmForceBox.value = newValue }
    }

    private static let priorities: [(String, Int32)] = [
        ("リアルタイム (-20)", -20), ("高 (-10)", -10), ("通常以上 (-5)", -5),
        ("通常 (0)", 0), ("通常以下 (5)", 5), ("低 (10)", 10), ("最低 (20)", 20),
    ]

    var body: some View {
        let q = search.lowercased()
        let total = Double(max(m.system.mem.total, 1))
        let rows = m.processes
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || String($0.pid) == q
                || $0.user.lowercased().contains(q) || $0.path.lowercased().contains(q) }
            .sorted(using: sortOrder)

        ScrollViewReader { proxy in
            Table(rows, selection: $selectionBox.value, sortOrder: $sortOrderBox.value) {
                TableColumn("名前", value: \.name) { p in
                    HStack(spacing: 6) {
                        Image(nsImage: IconCache.shared.icon(path: p.path, bundlePath: p.bundlePath))
                            .resizable().frame(width: 16, height: 16)
                        Text(p.name).lineLimit(1)
                    }
                }
                .width(min: 180, ideal: 240)
                TableColumn("PID", value: \.pid) { p in Text(String(p.pid)).monospacedDigit() }
                    .width(min: 45, ideal: 60)
                TableColumn("状態", value: \.statusCode) { p in Text(p.statusLong) }
                    .width(min: 45, ideal: 60)
                TableColumn("ユーザー名", value: \.user).width(min: 70, ideal: 110)
                TableColumn("CPU", value: \.cpu) { p in
                    HeatCell(text: String(format: "%.1f", p.cpu), level: p.cpu / 40)
                }
                .width(min: 50, ideal: 60)
                TableColumn("CPU 時間", value: \.cpuTime) { p in Text(Fmt.cpuTime(p.cpuTime)).monospacedDigit() }
                    .width(min: 65, ideal: 80)
                TableColumn("メモリ", value: \.memory) { p in
                    HeatCell(text: Fmt.bytes(p.memory), level: Double(p.memory) / total * 8)
                }
                .width(min: 70, ideal: 90)
                TableColumn("スレッド", value: \.threads) { p in
                    Text(p.limited ? "—" : "\(p.threads)").monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 45, ideal: 55)
                TableColumn("優先度", value: \.nice) { p in Text("\(p.nice)").monospacedDigit() }
                    .width(min: 40, ideal: 50)
                TableColumn("パス", value: \.path) { p in
                    Text(p.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .contextMenu(forSelectionType: pid_t.self) { ids in
                if let first = ids.first {
                    Button("タスクの終了") { m.endTask(pids: Array(ids), force: false, preferApp: false) }
                    Button("強制終了") { selection = ids; confirmForce = true }
                    Button("プロセス ツリーの終了") { for id in ids { m.endTree(pid: id) } }
                    Divider()
                    Menu("優先度の設定") {
                        ForEach(0..<Self.priorities.count, id: \.self) { i in
                            let item = Self.priorities[i]
                            Button(item.0) { for id in ids { m.setPriority(pid: id, nice: item.1) } }
                        }
                    }
                    Divider()
                    if let p = m.processes.first(where: { $0.pid == first }) {
                        Button("ファイルの場所を開く") { m.revealInFinder(path: p.path) }
                        Button("パスをコピー") { copy(p.path) }
                    }
                    Button("PID をコピー") { copy(ids.map { String($0) }.joined(separator: " ")) }
                }
            }
            .onDeleteCommand { m.endTask(pids: Array(selection), force: false, preferApp: false) }
            .confirmationDialog("選択したプロセスを強制終了しますか？", isPresented: $confirmForceBox.value) {
                Button("強制終了", role: .destructive) {
                    m.endTask(pids: Array(selection), force: true, preferApp: false)
                }
            } message: {
                Text("保存されていないデータは失われます。")
            }
            .onAppear {
                if let pid = m.focusPid {
                    selection = [pid]
                    m.focusPid = nil
                    DispatchQueue.main.async { proxy.scrollTo(pid, anchor: .center) }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { m.endTask(pids: Array(selection), force: false, preferApp: false) } label: {
                    Label("タスクを終了する", systemImage: "xmark.circle")
                }
                .help("タスクを終了する")
                .disabled(selection.isEmpty)
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
