import SwiftUI

@MainActor
struct ContentView: View {
    @EnvironmentObject private var m: Monitor
    @StateObject private var searchBox = Box<String>("")
    private var search: String {
        get { searchBox.value }
        nonmutating set { searchBox.value = newValue }
    }

    var body: some View {
        GeometryReader { geo in
            mainView(scale: m.uiScale(forWidth: geo.size.width))
        }
        .task { await m.run() }
    }

    private func mainView(scale: CGFloat) -> some View {
        NavigationSplitView {
            List {
                ForEach(Tab.allCases) { t in
                    SidebarButton(tab: t, selected: (m.tab ?? .processes) == t) {
                        m.tab = t
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String((Tab.allCases.firstIndex(of: t) ?? 0) + 1))), modifiers: .command)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180 * scale, ideal: 210 * scale, max: 300 * scale)
            .safeAreaInset(edge: .bottom) {
                SidebarFooter()
            }
        } detail: {
            Group {
                switch m.tab ?? .processes {
                case .processes: ProcessesView(search: search)
                case .performance: PerformanceView()
                case .history: HistoryView(search: search)
                case .startup: StartupView(search: search)
                case .users: UsersView(search: search)
                case .details: DetailsView(search: search)
                }
            }
            .id(m.tab ?? .processes)
            .navigationTitle((m.tab ?? .processes).title)
        }
        .searchable(text: $searchBox.value, placement: .toolbar, prompt: "名前・PID・ユーザーで検索")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker("リアルタイム更新の速度", selection: $m.speed) {
                        ForEach(UpdateSpeed.allCases) { s in Text(s.title).tag(s) }
                    }
                    Divider()
                    Toggle("ウィンドウの大きさに合わせて拡大", isOn: $m.autoScale)
                    Button("拡大") { m.zoomIn() }
                    Button("縮小") { m.zoomOut() }
                    Button("実際のサイズ（\(Int((m.zoom * 100).rounded()))% → 100%）") { m.zoomReset() }
                    Divider()
                    Toggle("常に手前に表示", isOn: $m.alwaysOnTop)
                } label: {
                    Label("オプション", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert(Text(m.alert?.title ?? ""),
               isPresented: Binding(get: { m.alert != nil }, set: { if !$0 { m.alert = nil } }),
               presenting: m.alert) { info in
            if let cmd = info.adminCommand {
                Button("管理者として実行") { m.runAsAdmin(cmd) }
                Button("キャンセル", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { info in
            if let cmd = info.adminCommand {
                Text(info.message + "\n\n管理者 (root) として次のコマンドを実行します:\n" + cmd)
            } else {
                Text(info.message)
            }
        }
        .environment(\.uiScale, scale)
        .font(.system(size: 13 * scale))
        .controlSize(scale >= 1.35 ? .large : .regular)
    }
}

@MainActor
private struct SidebarFooter: View {
    @Environment(\.uiScale) private var ui
    @EnvironmentObject private var m: Monitor
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Group {
                Text("CPU \(Fmt.percent(m.system.cpu.total))")
                Text("メモリ \(Fmt.percent(m.system.mem.percent))")
                Text("プロセス \(m.processes.count)")
                if m.speed == .paused { Text("更新を一時停止中").foregroundStyle(.orange) }
                Text(AppVersion.display)
                    .foregroundStyle(.tertiary)
                    .help("コミット: \(AppVersion.commit ?? "—")")
                    .padding(.top, 2)
            }
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }
}

/// サイドバーの項目 (クリックで確実にタブを切り替える)
@MainActor
private struct SidebarButton: View {
    @Environment(\.uiScale) private var ui
    let tab: Tab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(tab.title, systemImage: tab.icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
                )
                .overlay(alignment: .leading) {
                    if selected {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor)
                            .frame(width: 3 * ui, height: 16 * ui)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fontWeight(selected ? .semibold : .regular)
    }
}
