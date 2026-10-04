import SwiftUI
import AppKit

/// アップデートの確認・ダウンロード・インストールを行うシート
@MainActor
struct UpdateSheet: View {
    @EnvironmentObject private var u: Updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text("現在のバージョン: v\(u.current)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            content
            HStack {
                Toggle("起動時に確認する", isOn: $u.autoCheck)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var title: String {
        switch u.state {
        case .idle, .checking: return "アップデートを確認しています…"
        case .upToDate: return "最新のバージョンです"
        case .available(let r): return "新しいバージョン v\(r.version) があります"
        case .downloading(let r): return "v\(r.version) をダウンロード・検証しています…"
        case .installing: return "インストールしています…"
        case .failed: return "アップデートできませんでした"
        }
    }

    @ViewBuilder private var content: some View {
        switch u.state {
        case .idle, .checking, .downloading, .installing:
            ProgressView().progressViewStyle(.linear)
        case .upToDate:
            Text("お使いのシステムモニターは最新です。").foregroundStyle(.secondary)
        case .available(let r):
            ScrollView {
                Text(Self.cleanNotes(r.notes))
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 180)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            Text("ダウンロード後、ハッシュ値・バンドル ID・バージョン・署名を確認してから置き換え、自動で再起動します。")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let msg):
            Text(msg).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch u.state {
        case .available(let r):
            Button("このバージョンをスキップ") { u.skip(r) }
            Button("あとで") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("今すぐアップデート") { u.install(r) }
                .keyboardShortcut(.defaultAction)
        case .downloading, .installing:
            EmptyView()
        case .failed:
            Button("Releases を開く") {
                NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repo)/releases/latest")!)
            }
            Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
        default:
            Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
        }
    }

    /// Markdown の見出し記号などを軽く取り除いて読みやすくする
    static func cleanNotes(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = String(line)
            while l.hasPrefix("#") { l.removeFirst() }
            if l.hasPrefix("- ") { l = "• " + l.dropFirst(2) }
            return l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
