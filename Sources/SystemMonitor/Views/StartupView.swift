import SwiftUI
import AppKit

@MainActor
struct StartupView: View {
    @Environment(\.uiScale) private var ui
    @EnvironmentObject private var m: Monitor
    let search: String

    @StateObject private var itemsBox = Box<[LaunchItem]>([])

    private var items: [LaunchItem] {

        get { itemsBox.value }

        nonmutating set { itemsBox.value = newValue }

    }
    @StateObject private var selectionBox = Box<Set<String>>([])
    private var selection: Set<String> {
        get { selectionBox.value }
        nonmutating set { selectionBox.value = newValue }
    }
    @StateObject private var sortOrderBox = Box<[KeyPathComparator<LaunchItem>]>([KeyPathComparator(\.label)])
    private var sortOrder: [KeyPathComparator<LaunchItem>] {
        get { sortOrderBox.value }
        nonmutating set { sortOrderBox.value = newValue }
    }
    @StateObject private var loadingBox = Box<Bool>(false)
    private var loading: Bool {
        get { loadingBox.value }
        nonmutating set { loadingBox.value = newValue }
    }

    private var rows: [LaunchItem] {
        let q = search.lowercased()
        let filtered = q.isEmpty ? items : items.filter {
            $0.label.lowercased().contains(q) || $0.program.lowercased().contains(q)
        }
        return filtered.sorted(using: sortOrder)
    }

    private var selectedItems: [LaunchItem] { items.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("ログイン時やシステム起動時に自動で実行される LaunchAgents / LaunchDaemons"))
                    .scaledFont(.callout).foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Text(L("%@ 件 有効 / 全 %@ 件", "\(items.filter { !$0.disabled }.count)", "\(items.count)"))
                    .scaledFont(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()

            Table(rows, selection: $selectionBox.value, sortOrder: $sortOrderBox.value) {
                TableColumn(L("名前"), value: \.label) { item in
                    HStack(spacing: 6) {
                        Image(nsImage: IconCache.shared.icon(path: item.program, bundlePath: nil))
                            .resizable().frame(width: 16 * ui, height: 16 * ui)
                        Text(item.label).lineLimit(1)
                    }
                }
                .width(min: 220 * ui, ideal: 300 * ui)
                TableColumn(L("発行元"), value: \.publisher).width(min: 70 * ui, ideal: 100 * ui)
                TableColumn(L("種類"), value: \.kindName).width(min: 90 * ui, ideal: 130 * ui)
                TableColumn(L("状態"), value: \.statusText) { item in
                    Text(item.statusText).foregroundStyle(item.disabled ? Color.secondary : Color.primary)
                }
                .width(min: 40 * ui, ideal: 50 * ui)
                TableColumn(L("実行状況"), value: \.runningText).width(min: 50 * ui, ideal: 60 * ui)
                TableColumn(L("自動起動"), value: \.runAtLoadText).width(min: 50 * ui, ideal: 60 * ui)
                TableColumn(L("プログラム"), value: \.program) { item in
                    Text(item.program).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .contextMenu(forSelectionType: String.self) { ids in
                let targets = items.filter { ids.contains($0.id) }
                if let first = targets.first {
                    if first.disabled {
                        Button(L("有効化")) { setEnabled(targets, true) }
                    } else {
                        Button(L("無効化")) { setEnabled(targets, false) }
                    }
                    Divider()
                    Button(L("plist を Finder で表示")) {
                        NSWorkspace.shared.activateFileViewerSelecting(targets.map { URL(fileURLWithPath: $0.path) })
                    }
                    Button(L("プログラムの場所を開く")) { m.revealInFinder(path: first.program) }
                    Button(L("plist を開く")) { NSWorkspace.shared.open(URL(fileURLWithPath: first.path)) }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: { Label(L("ログイン項目設定"), systemImage: "gearshape") }
                .help(L("システム設定の「ログイン項目」を開く"))
                Button { Task { await reload() } } label: { Label(L("再読み込み"), systemImage: "arrow.clockwise") }
                Button { setEnabled(selectedItems, true) } label: { Label(L("有効化"), systemImage: "checkmark.circle") }
                    .disabled(selectedItems.isEmpty)
                Button { setEnabled(selectedItems, false) } label: { Label(L("無効化"), systemImage: "nosign") }
                    .disabled(selectedItems.isEmpty)
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        let paths = Set(m.processes.map(\.path))
        items = await Task.detached(priority: .userInitiated) {
            LaunchItemLoader.load(runningPaths: paths)
        }.value
        loading = false
    }

    private func setEnabled(_ targets: [LaunchItem], _ enabled: Bool) {
        Task {
            var adminCommands: [String] = []
            for t in targets {
                let r = await Task.detached { LaunchItemLoader.setEnabled(t, enabled: enabled) }.value
                if !r.ok, let cmd = r.adminCommand { adminCommands.append(cmd) }
            }
            if !adminCommands.isEmpty {
                m.alert = AlertInfo(
                    title: L("管理者権限が必要です"),
                    message: L("システム デーモンなどの変更には管理者パスワードが必要です。実行しますか？"),
                    adminCommand: adminCommands.joined(separator: "; "))
            }
            await reload()
        }
    }
}
