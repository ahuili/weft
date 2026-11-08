import AppKit
import SwiftUI
import WeftCore

/// 数字槽位条：1~9 九个格子，一眼看到每个号码对应谁。点一下跳过去；右键钉住 / 清空。
struct SlotBar: View {
    @ObservedObject var model: AppModel
    var compact = false
    /// 侧栏 / 总控里点了之后要做的事（通常是关面板）
    var after: () -> Void = {}

    var body: some View {
        let _ = model.slotRevision
        let key = model.slotKey
        HStack(spacing: compact ? 3 : 6) {
            if !compact {
                Text("\(key) 数字").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    .help("\(key)1~9 直达钉住的窗口；\(key)⇧数字 把当前窗口钉上去；在已经是它的时候再按一次，跳回刚才那个")
            }
            let ghosts = model.slotSuggestions()
            ForEach(Array(SlotStore.range), id: \.self) { n in cell(n, ghost: ghosts[n]) }
        }
    }

    @ViewBuilder func cell(_ n: Int, ghost: WindowInfo?) -> some View {
        let target = model.slotTarget(n)
        let size: CGFloat = compact ? 28 : 34
        Button {
            if case .empty = target {
                // 空号码上的推荐：点一下就钉上并切过去
                guard ghost != nil else { return }
                after()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { model.acceptSlotSuggestion(n) }
                return
            }
            after()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { model.jumpSlot(n) }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    switch target {
                    case .window(let w): Image(nsImage: appIcon(w.pid)).resizable().padding(3)
                    case .app(let bid, _):
                        Image(nsImage: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
                            .resizable().padding(3).opacity(0.45)
                    case .empty:
                        if let g = ghost { Image(nsImage: appIcon(g.pid)).resizable().padding(5).opacity(0.35).saturation(0.2) } else { Color.clear }
                    }
                }
                .frame(width: size, height: size)
                Text("\(n)").font(.system(size: compact ? 9 : 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(isEmpty(target) ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.white))
                    .padding(.horizontal, 3)
                    .background(isEmpty(target) ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Color.purple.opacity(0.9)), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isEmpty(target) ? .center : .bottomTrailing)
            }
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(isEmpty(target) ? 0.04 : 0.10)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: isEmpty(target) ? [3, 2] : [])))
        }
        .buttonStyle(.plain)
        .help(ghost.map { g in "\(model.slotKey)\(n) 还空着 · 推荐「\(g.appName) · \(g.title)」（你最常用的之一），点一下钉上" } ?? help(n, target))
        .contextMenu {
            if case .window(let w) = target { Text("\(n) 号：\(w.appName) · \(w.title)") }
            if let cur = model.currentWindow { Button("把「\(cur.appName)」钉到 \(n) 号") { model.pinSlot(n, window: cur) } }
            if !isEmpty(target) { Button("清空 \(n) 号") { model.clearSlot(n) } }
        }
    }

    func isEmpty(_ t: SlotTarget) -> Bool { if case .empty = t { return true }; return false }

    func help(_ n: Int, _ t: SlotTarget) -> String {
        let k = model.slotKey
        switch t {
        case .window(let w): return "\(k)\(n)：\(w.appName) · \(w.title)"
        case .app(_, let name): return "\(k)\(n)：\(name)（窗口没开，按下会打开它）"
        case .empty: return "\(k)\(n) 还是空的：切到某个窗口后按 \(k)⇧\(n) 钉上来，或在窗口上右键"
        }
    }
}

/// 窗口右键菜单里的「钉到数字」
struct SlotMenu: View {
    @ObservedObject var model: AppModel
    let window: WindowInfo
    var body: some View {
        if model.settings.slotModifier != .off {
            Menu("钉到数字（\(model.slotKey)1~9 直达）") {
                ForEach(Array(SlotStore.range), id: \.self) { n in
                    let t = model.slots.bindings[n]
                    Button("\(n)" + (t.map { $0.windowID == window.id ? "  ✓" : "  （现在是 \($0.appName)）" } ?? "")) { model.pinSlot(n, window: window) }
                }
                if let n = model.slots.slot(of: window.id) { Divider(); Button("取消（\(n) 号）") { model.clearSlot(n) } }
            }
        }
    }
}
