import SwiftUI

@MainActor
struct ContentView: View {
    @EnvironmentObject private var m: Monitor
    @EnvironmentObject private var updater: Updater
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
        .task { updater.checkOnLaunch() }
        .onReceive(NotificationCenter.default.publisher(for: Notifier.openNetAlerts)) { _ in
            m.openNetworkAlerts()
        }
        .sheet(isPresented: $updater.showSheet) {
            UpdateSheet().environmentObject(updater)
        }
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
        .searchable(text: $searchBox.value, placement: .toolbar, prompt: L("名前・PID・ユーザーで検索"))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Picker(L("リアルタイム更新の速度"), selection: $m.speed) {
                        ForEach(UpdateSpeed.allCases) { s in Text(s.title).tag(s) }
                    }
                    Divider()
                    Toggle(L("ウィンドウの大きさに合わせて拡大"), isOn: $m.autoScale)
                    Button(L("拡大")) { m.zoomIn() }
                    Button(L("縮小")) { m.zoomOut() }
                    Button(L("実際のサイズ（%@%% → 100%%）", "\(Int((m.zoom * 100).rounded()))")) { m.zoomReset() }
                    Divider()
                    Toggle(L("常に手前に表示"), isOn: $m.alwaysOnTop)
                    Picker("言語 / Language", selection: Binding(
                        get: { AppLanguage.current },
                        set: { AppLanguage.set($0) })) {
                        ForEach(AppLanguage.allCases) { l in Text(l.title).tag(l) }
                    }
                    Divider()
                    Button(L("アップデートを確認…")) { Task { await updater.check(userInitiated: true) } }
                    Toggle(L("起動時にアップデートを確認"), isOn: $updater.autoCheck)
                } label: {
                    // アイコン (…) だけだと分かりにくいので文字で表示する
                    Text(L("オプション"))
                }
                .help(L("更新速度・表示サイズ・言語・アップデートなどの設定"))
            }
        }
        .alert(Text(m.alert?.title ?? ""),
               isPresented: Binding(get: { m.alert != nil }, set: { if !$0 { m.alert = nil } }),
               presenting: m.alert) { info in
            if let cmd = info.adminCommand {
                Button(L("管理者として実行")) { m.runAsAdmin(cmd) }
                Button(L("キャンセル"), role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { info in
            if let cmd = info.adminCommand {
                Text(info.message + L("\n\n管理者 (root) として次のコマンドを実行します:\n") + cmd)
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
    @EnvironmentObject private var updater: Updater
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Group {
                Text("CPU \(Fmt.percent(m.system.cpu.total))")
                Text(L("メモリ %@", "\(Fmt.percent(m.system.mem.percent))"))
                Text(L("プロセス %@", "\(m.processes.count)"))
                if m.speed == .paused { Text(L("更新を一時停止中")).foregroundStyle(.orange) }
                Text(AppVersion.display)
                    .foregroundStyle(.tertiary)
                    .help(L("コミット: %@", "\(AppVersion.commit ?? "—")"))
                    .padding(.top, 2)
                if case .available(let r) = updater.state {
                    Button(L("⬆︎ v%@ にアップデート", "\(r.version)")) { updater.showSheet = true }
                        .buttonStyle(.link)
                }
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
