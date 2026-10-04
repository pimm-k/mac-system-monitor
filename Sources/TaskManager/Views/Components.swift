import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 折れ線グラフ (Windows タスクマネージャー風)

struct GraphSeries {
    var values: [Double]
    var color: Color
    var filled: Bool = true
    var dashed: Bool = false
}

struct LineGraph: View {
    @Environment(\.uiScale) private var ui
    var series: [GraphSeries]
    var maxValue: Double
    var frameColor: Color
    var capacity: Int = Monitor.historyLength
    var gridDivisions: Int = 10

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(rect), with: .color(Color(nsColor: .textBackgroundColor)))

            // グリッド
            if gridDivisions > 0 {
                var grid = Path()
                for i in 1..<gridDivisions {
                    let y = size.height * CGFloat(i) / CGFloat(gridDivisions)
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                let vLines = 20
                for i in 1..<vLines {
                    let x = size.width * CGFloat(i) / CGFloat(vLines)
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                ctx.stroke(grid, with: .color(frameColor.opacity(0.13)), lineWidth: 0.5)
            }

            let maxV = maxValue > 0 ? maxValue : 1
            let step = size.width / CGFloat(max(capacity - 1, 1))
            for s in series {
                let pts = Array(s.values.suffix(capacity))
                guard pts.count >= 2 else { continue }
                let startX = size.width - CGFloat(pts.count - 1) * step
                var line = Path()
                for (i, v) in pts.enumerated() {
                    let x = startX + CGFloat(i) * step
                    let y = size.height - CGFloat(min(max(v / maxV, 0), 1)) * (size.height - 1)
                    if i == 0 { line.move(to: CGPoint(x: x, y: y)) } else { line.addLine(to: CGPoint(x: x, y: y)) }
                }
                if s.filled {
                    var area = line
                    area.addLine(to: CGPoint(x: size.width, y: size.height))
                    area.addLine(to: CGPoint(x: startX, y: size.height))
                    area.closeSubpath()
                    ctx.fill(area, with: .color(s.color.opacity(0.14)))
                }
                ctx.stroke(line, with: .color(s.color),
                           style: StrokeStyle(lineWidth: 1.3, dash: s.dashed ? [4, 3] : []))
            }
        }
        .overlay(Rectangle().stroke(frameColor.opacity(0.7), lineWidth: 1))
    }
}

/// スループット系グラフの上限を 1-2-5 系で丸める
func niceMax(_ values: [Double], minimum: Double = 100 * 1024) -> Double {
    let m = max(values.max() ?? 0, minimum) * 1.1
    let exp = pow(10, floor(log10(m)))
    for f in [1.0, 2.0, 5.0, 10.0] where f * exp >= m { return f * exp }
    return 10 * exp
}

// MARK: - アイコンキャッシュ

@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    private lazy var generic: NSImage = NSWorkspace.shared.icon(for: .unixExecutable)

    func icon(path: String, bundlePath: String?) -> NSImage {
        let key: String
        if let b = bundlePath {
            key = b
        } else if let r = path.range(of: ".app/") {
            key = String(path[..<r.lowerBound]) + ".app"
        } else {
            return generic
        }
        if let img = cache[key] { return img }
        let img = NSWorkspace.shared.icon(forFile: key)
        cache[key] = img
        return img
    }
}

// MARK: - 小物

struct HeatCell: View {
    @Environment(\.uiScale) private var ui
    let text: String
    let level: Double
    var body: some View {
        Text(text)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(text.isEmpty ? Color.clear : Palette.heat(level))
    }
}

struct Stat: View {
    @Environment(\.uiScale) private var ui
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).scaledFont(.caption).foregroundStyle(.secondary)
            Text(value).scaledFont(.title2).monospacedDigit()
        }
    }
}

struct InfoGrid: View {
    @Environment(\.uiScale) private var ui
    let rows: [(String, String)]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 5) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    Text(rows[i].0).foregroundStyle(.secondary)
                    Text(rows[i].1).textSelection(.enabled)
                }
            }
        }
        .scaledFont(.callout)
    }
}

// MARK: - @State の代わり
// macOS 27 SDK では @State がマクロになり、Command Line Tools だけでは
// ビルドできないため、ObservableObject + @StateObject で状態を保持する。
final class Box<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

// MARK: - 表示倍率 (ウィンドウの大きさ・⌘+ / ⌘− に合わせて文字やグラフを拡大)

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// 画面全体の表示倍率 (1.0 = 標準)
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

/// macOS の標準文字サイズに倍率を掛けるためのスタイル
enum UIFontStyle {
    case largeTitle, title, title2, title3, headline, body, callout, subheadline, footnote, caption, caption2

    var size: CGFloat {
        switch self {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline, .body: return 13
        case .callout: return 12
        case .subheadline: return 11
        case .footnote, .caption: return 10
        case .caption2: return 10
        }
    }
    var weight: Font.Weight { self == .headline ? .bold : .regular }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.uiScale) private var ui
    let size: CGFloat
    let weight: Font.Weight
    let mono: Bool

    func body(content: Content) -> some View {
        let font = Font.system(size: size * ui, weight: weight)
        return content.font(mono ? font.monospacedDigit() : font)
    }
}

extension View {
    /// 表示倍率に合わせて大きさが変わるフォント
    func scaledFont(_ style: UIFontStyle, mono: Bool = false) -> some View {
        modifier(ScaledFont(size: style.size, weight: style.weight, mono: mono))
    }

    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, mono: Bool = false) -> some View {
        modifier(ScaledFont(size: size, weight: weight, mono: mono))
    }
}
