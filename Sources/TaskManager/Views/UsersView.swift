import SwiftUI

struct UserRow: Identifiable, Hashable {
    var id: uid_t
    var name: String
    var count: Int
    var cpu: Double
    var memory: UInt64
    var disk: Double
}

@MainActor
struct UsersView: View {
    @EnvironmentObject private var m: Monitor
    let search: String

    @StateObject private var selectionBox = Box<Set<uid_t>>([])

    private var selection: Set<uid_t> {

        get { selectionBox.value }

        nonmutating set { selectionBox.value = newValue }

    }
    @StateObject private var sortOrderBox = Box<[KeyPathComparator<UserRow>]>([KeyPathComparator(\.cpu, order: .reverse)])
    private var sortOrder: [KeyPathComparator<UserRow>] {
        get { sortOrderBox.value }
        nonmutating set { sortOrderBox.value = newValue }
    }
    @StateObject private var procSortBox = Box<[KeyPathComparator<ProcItem>]>([KeyPathComparator(\.cpu, order: .reverse)])
    private var procSort: [KeyPathComparator<ProcItem>] {
        get { procSortBox.value }
        nonmutating set { procSortBox.value = newValue }
    }
    @StateObject private var procSelectionBox = Box<Set<pid_t>>([])
    private var procSelection: Set<pid_t> {
        get { procSelectionBox.value }
        nonmutating set { procSelectionBox.value = newValue }
    }

    var body: some View {
        let users = buildUsers()
        let total = Double(max(m.system.mem.total, 1))
        let procs = m.processes
            .filter { selection.contains($0.uid) }
            .filter { search.isEmpty || $0.name.lowercased().contains(search.lowercased()) }
            .sorted(using: procSort)

        VSplitView {
            Table(users, selection: $selectionBox.value, sortOrder: $sortOrderBox.value) {
                TableColumn("ユーザー", value: \.name) { u in
                    Label(u.name, systemImage: u.id == 0 ? "lock.shield" : "person.crop.circle")
                }
                .width(min: 160, ideal: 220)
                TableColumn("UID", value: \.id) { u in Text(String(u.id)).monospacedDigit() }
                    .width(min: 50, ideal: 60)
                TableColumn("プロセス数", value: \.count) { u in Text("\(u.count)").monospacedDigit() }
                    .width(min: 60, ideal: 80)
                TableColumn("CPU", value: \.cpu) { u in HeatCell(text: Fmt.percent(u.cpu), level: u.cpu / 40) }
                TableColumn("メモリ", value: \.memory) { u in
                    HeatCell(text: Fmt.bytes(u.memory), level: Double(u.memory) / total * 3)
                }
                TableColumn("ディスク", value: \.disk) { u in
                    HeatCell(text: Fmt.rate(u.disk), level: u.disk / 20_000_000)
                }
            }
            .frame(minHeight: 160)

            VStack(alignment: .leading, spacing: 0) {
                Text(selection.isEmpty ? "ユーザーを選択するとプロセスを表示します" : "選択したユーザーのプロセス (\(procs.count))")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                Table(procs, selection: $procSelectionBox.value, sortOrder: $procSortBox.value) {
                    TableColumn("名前", value: \.name) { p in
                        HStack(spacing: 6) {
                            Image(nsImage: IconCache.shared.icon(path: p.path, bundlePath: p.bundlePath))
                                .resizable().frame(width: 16, height: 16)
                            Text(p.name).lineLimit(1)
                        }
                    }
                    TableColumn("PID", value: \.pid) { p in Text(String(p.pid)).monospacedDigit() }
                    TableColumn("CPU", value: \.cpu) { p in HeatCell(text: Fmt.percent(p.cpu), level: p.cpu / 40) }
                    TableColumn("メモリ", value: \.memory) { p in
                        HeatCell(text: Fmt.bytes(p.memory), level: Double(p.memory) / total * 8)
                    }
                }
                .contextMenu(forSelectionType: pid_t.self) { ids in
                    if !ids.isEmpty {
                        Button("タスクの終了") { m.endTask(pids: Array(ids), force: false, preferApp: false) }
                        Button("強制終了") { m.endTask(pids: Array(ids), force: true, preferApp: false) }
                    }
                }
            }
            .frame(minHeight: 160)
        }
    }

    private func buildUsers() -> [UserRow] {
        var map: [uid_t: UserRow] = [:]
        for p in m.processes {
            var u = map[p.uid] ?? UserRow(id: p.uid, name: p.user, count: 0, cpu: 0, memory: 0, disk: 0)
            u.count += 1
            u.cpu += p.cpu
            u.memory += p.memory
            u.disk += p.disk
            map[p.uid] = u
        }
        let q = search.lowercased()
        return map.values
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || String($0.id) == q || !selection.isEmpty }
            .sorted(using: sortOrder)
    }
}
