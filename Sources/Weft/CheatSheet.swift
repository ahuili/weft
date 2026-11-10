import AppKit
import SwiftUI
import WeftCore

/// 快捷键速查：只要记住前三个，其余的忘了就来这里看（总控里按 ?，或菜单栏 › 快捷键速查）
@MainActor
final class CheatSheet {
    let model: AppModel
    private var panel: KeyPanel?
    private var monitor: Any?
    private var clickMonitor: Any?

    init(model: AppModel) { self.model = model }

    var isVisible: Bool { panel != nil }
    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard panel == nil, let screen = mouseScreen() else { return }
        let p = KeyPanel.make(level: .popUpMenu)
        let host = NSHostingView(rootView: CheatSheetView(settings: model.settings, close: { [weak self] in self?.hide() }))
        p.contentView = host
        let size = host.fittingSize
        let v = screen.visibleFrame
        p.setFrame(NSRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        panel = p
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.hide() }
            return nil
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
    }
}

struct CheatSheetView: View {
    let settings: WeftSettings
    var close: () -> Void

    struct Row: Identifiable { let id = UUID(); let key: String; let what: String }

    var core: [Row] {
        var r = [Row(key: settings.stageTrigger.display, what: "舞台模式：选版式、挑窗口；再按一次退出")]
        if settings.quickSwitch != .off { r.append(Row(key: settings.quickSwitch.display, what: "按住连按，在窗口之间切；松开就过去")) }
        if settings.sceneSwipe { r.append(Row(key: "⌃ ←  /  ⌃ →", what: "切场景（四指左右滑也行），换的是鼠标所在的屏")) }
        return r
    }

    var mouse: [Row] {
        var r: [Row] = []
        if settings.shelfEdge != .off {
            r.append(Row(key: settings.shelfHandle ? "屏幕边的小把手" : "鼠标碰\(settings.shelfEdge == .left ? "左" : "右")边缘", what: "打开侧栏：所有窗口，点一下就上台"))
        }
        r.append(Row(key: "拖窗口到另一块屏", what: "自动插进那块屏的场景"))
        r.append(Row(key: "拖窗口时按住 ⇧", what: "叠到落点那一格上（一格最多 5 个）"))
        r.append(Row(key: "⌥ + 滚轮（标题栏上）", what: "这一格原地换窗口；叠着的一摞会展开来选"))
        return r
    }

    var extra: [Row] {
        var r: [Row] = []
        if settings.hubTrigger != .off { r.append(Row(key: settings.hubTrigger.display, what: "总控：搜索、整理桌面（⌘K）、排布建议（⌘J）")) }
        if settings.shelfTrigger != .off { r.append(Row(key: settings.shelfTrigger.display, what: "用键盘打开侧栏，按数字直达")) }
        if settings.sceneTrigger != .off { r.append(Row(key: settings.sceneTrigger.display, what: "场景切换器（和 ⌃←/→ 是同一排卡片）")) }
        if settings.slotModifier != .off {
            let m = settings.slotModifier.symbol
            r.append(Row(key: "\(m)1~9  /  \(m)⇧1~9", what: "跳到 n 号窗口 / 把当前窗口钉到 n 号"))
        }
        return r
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("快捷键速查").font(.system(size: 17, weight: .heavy, design: .rounded))
                Spacer()
                Text("按任意键关闭").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            group("只要记这几个", core, strong: true)
            group("鼠标就能做的（界面上会提示，不用记）", mouse)
            if !extra.isEmpty { group("想用再用", extra) }
            Text("键位都可以在 设置 › 快捷键 里改或关掉").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: 18).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.15)))
        .padding(10)
        .onTapGesture { close() }
    }

    func group(_ title: String, _ rows: [Row], strong: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(strong ? Color.purple : .secondary)
            ForEach(rows) { r in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(r.key).font(.system(size: strong ? 14 : 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(strong ? 0.16 : 0.08)))
                        .frame(width: 178, alignment: .leading)
                    Text(r.what).font(.system(size: strong ? 13 : 12)).foregroundStyle(strong ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
