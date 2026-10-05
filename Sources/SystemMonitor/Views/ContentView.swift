import SwiftUI

@MainActor
struct ContentView: View {
    @EnvironmentObject private var m: Monitor
    @EnvironmentObject private var updater: Updater
    @StateObject private var firstRunBox = Box<Bool>(!AppLanguage.hasChosen)
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
        .task { if AppLanguage.hasChosen { await updater.runAutoCheck() } }
        .sheet(isPresented: $firstRunBox.value) {
            LanguageWelcomeSheet { lang in
                firstRunBox.value = false
                AppLanguage.chooseOnFirstRun(lang)
            }
            .interactiveDismissDisabled()
        }
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
            if let rel = updater.availableRelease {
                ToolbarItem(placement: .automatic) {
                    Button {
                        updater.showSheet = true
                    } label: {
                        Label(L("v%@ にアップデート", "\(rel.version)"), systemImage: "arrow.down.circle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .tint(.accentColor)
                    .help(L("新しいバージョン v%@ があります", "\(rel.version)"))
                }
            }
            ToolbarItem(placement: .automatic) {
                // メニューを開いている間に毎秒の更新で作り直されないよう、
                // 設定値が変わったときだけ再描画する別ビューにしている
                OptionsMenu(
                    speed: m.speed,
                    autoScale: m.autoScale,
                    zoomPercent: Int((m.zoom * 100).rounded()),
                    alwaysOnTop: m.alwaysOnTop,
                    autoCheck: updater.autoCheck,
                    actions: OptionsMenu.Actions(
                        setSpeed: { m.speed = $0 },
                        setAutoScale: { m.autoScale = $0 },
                        zoomIn: { m.zoomIn() },
                        zoomOut: { m.zoomOut() },
                        zoomReset: { m.zoomReset() },
                        setAlwaysOnTop: { m.alwaysOnTop = $0 },
                        checkUpdate: { Task { await updater.check(userInitiated: true) } },
                        setAutoCheck: { updater.autoCheck = $0 }))
                .equatable()
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

/// ツールバーの「オプション」メニュー。
/// 選択肢はサブメニューにせずメニュー内に直接並べ、カーソル移動で閉じにくくしている。
@MainActor
private struct OptionsMenu: View, Equatable {
    struct Actions {
        let setSpeed: (UpdateSpeed) -> Void
        let setAutoScale: (Bool) -> Void
        let zoomIn: () -> Void
        let zoomOut: () -> Void
        let zoomReset: () -> Void
        let setAlwaysOnTop: (Bool) -> Void
        let checkUpdate: () -> Void
        let setAutoCheck: (Bool) -> Void
    }

    let speed: UpdateSpeed
    let autoScale: Bool
    let zoomPercent: Int
    let alwaysOnTop: Bool
    let autoCheck: Bool
    let actions: Actions

    nonisolated static func == (a: OptionsMenu, b: OptionsMenu) -> Bool {
        a.speed == b.speed && a.autoScale == b.autoScale && a.zoomPercent == b.zoomPercent
            && a.alwaysOnTop == b.alwaysOnTop && a.autoCheck == b.autoCheck
    }

    var body: some View {
        Menu {
            Picker(L("リアルタイム更新の速度"), selection: Binding(get: { speed }, set: actions.setSpeed)) {
                ForEach(UpdateSpeed.allCases) { s in Text(s.title).tag(s) }
            }
            .pickerStyle(.inline)

            Section(L("表示サイズ")) {
                Toggle(L("ウィンドウの大きさに合わせて拡大"), isOn: Binding(get: { autoScale }, set: actions.setAutoScale))
                Button(L("拡大")) { actions.zoomIn() }
                Button(L("縮小")) { actions.zoomOut() }
                Button(L("実際のサイズ（%@%% → 100%%）", "\(zoomPercent)")) { actions.zoomReset() }
                Toggle(L("常に手前に表示"), isOn: Binding(get: { alwaysOnTop }, set: actions.setAlwaysOnTop))
            }

            Picker("言語 / Language", selection: Binding(
                get: { AppLanguage.current },
                set: { AppLanguage.set($0) })) {
                ForEach(AppLanguage.allCases) { l in Text(l.title).tag(l) }
            }
            .pickerStyle(.inline)

            Section(L("アップデート")) {
                Button(L("アップデートを確認…")) { actions.checkUpdate() }
                Toggle(L("起動時にアップデートを確認"), isOn: Binding(get: { autoCheck }, set: actions.setAutoCheck))
            }
        } label: {
            // アイコン (…) だけだと分かりにくいので文字で表示する
            Text(L("オプション"))
        }
        .help(L("更新速度・表示サイズ・言語・アップデートなどの設定"))
    }
}

/// 初回起動時の言語選択 (日本語と英語を併記。初期値はシステムの設定に従う)
@MainActor
private struct LanguageWelcomeSheet: View {
    let onDone: (AppLanguage) -> Void
    @StateObject private var choiceBox = Box<AppLanguage>(AppLanguage.current)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "システムモニターへようこそ").font(.title2.bold())
                    Text(verbatim: "Welcome to System Monitor").foregroundStyle(.secondary)
                }
            }
            Text(verbatim: "表示する言語を選んでください。\nChoose the display language.")
            Picker(selection: $choiceBox.value) {
                Text(verbatim: "システムの設定に従う / Use System Setting").tag(AppLanguage.system)
                Text(verbatim: "日本語").tag(AppLanguage.ja)
                Text(verbatim: "English").tag(AppLanguage.en)
            } label: {
                EmptyView()
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(verbatim: "あとから「オプション → 言語 / Language」で変更できます。\nYou can change it later in Options → 言語 / Language.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button {
                    onDone(choiceBox.value)
                } label: {
                    Text(verbatim: "OK").frame(minWidth: 60)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

