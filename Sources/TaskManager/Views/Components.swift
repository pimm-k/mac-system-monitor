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
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2).monospacedDigit()
        }
    }
}

struct InfoGrid: View {
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
        .font(.callout)
    }
}

// MARK: - @State の代わり
// macOS 27 SDK では @State がマクロになり、Command Line Tools だけでは
// ビルドできないため、ObservableObject + @StateObject で状態を保持する。
final class Box<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}
