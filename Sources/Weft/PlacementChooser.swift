import AppKit
import SwiftUI
import WeftCore

// MARK: - 放进哪一块
//
// 你点 Dock / ⌘Tab 切到一个不在任何场景里的窗口：它先单独成一个新场景（马上就能用），
// 屏幕顶部浮出一张小卡片：刚才那个场景的缩略图，每一块都能点——鼠标停在哪块，屏幕上对应的位置就亮起来，
// 点下去就回到刚才的场景、这一块换成它；也可以「多加一格」。不理它，8 秒后自己收起，保持单独。

@MainActor
final class PlacementChooser {
    let model: AppModel
    private var panel: KeyPanel?
    private var glow: NSPanel?
    private var timer: Timer?
    private var offer: PlacementOffer?
    private var ticks = 0
    private let state = ChooserState()

    init(model: AppModel) { self.model = model }

    func show(_ o: PlacementOffer) {
        hide(keep: false)
        guard let d = model.profile.display(uuid: o.display) else { return }
        offer = o
        state.offer = o
        state.remaining = 1
        state.hovering = false
        ticks = 0
        // 能变成 key（点得动按钮），但出现时不抢键盘：你正在新窗口里打字也不受影响
        let p = panel ?? KeyPanel.make(level: .popUpMenu)
        p.contentView = FirstClickHostingView(rootView: ChooserView(
            model: model, state: state,
            pick: { [weak self] slot in self?.choose(slot) },
            stack: { [weak self] slot in self?.choose(slot, stack: true) },
            keep: { [weak self] in self?.hide(keep: true) },
            float: { [weak self] in self?.floatIt() },
            move: { [weak self] u in self?.move(u) },
            hover: { [weak self] slot in self?.highlight(slot) }))
        panel = p
        let primaryH = NSScreen.screens.first?.frame.height ?? d.frame.height
        let fit = p.contentView?.fittingSize ?? .zero
        let w: CGFloat = max(420, min(760, fit.width)), h: CGFloat = max(180, fit.height)
        let top = primaryH - d.visible.minY
        let target = NSRect(x: d.frame.minX + d.frame.width / 2 - w / 2, y: top - h - 6, width: w, height: h)
        p.setFrame(target.offsetBy(dx: 0, dy: 30), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.1)
            p.animator().setFrame(target, display: true)
            p.animator().alphaValue = 1
        }
        // 5 秒倒计时，鼠标停在卡片上时暂停
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel else { return }
                let inside = p.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
                self.state.hovering = inside
                if inside { return }
                self.state.remaining -= 0.05 / 5
                // 你已经去用别的窗口了（过了头一秒）：不再等，收起来
                self.ticks += 1
                if self.ticks > 20, self.ticks % 6 == 0, let o = self.offer, let f = self.model.system.focusedWindowID(), f != o.window.id { self.hide(keep: true) }
                if self.state.remaining <= 0 { self.hide(keep: true) }
            }
        }
    }

    func debugChoose(_ slot: Int?) { choose(slot) }

    func debugStack(_ slot: Int) { choose(slot, stack: true) }

    private func choose(_ slot: Int?, stack: Bool = false) {
        guard let o = offer else { return }
        hide(keep: false)
        model.acceptPlacement(o, slot: slot, stack: stack)
    }

    /// 「以后随手」：这个 App 不进场景，刚才的场景原样回来，它浮在上面
    private func floatIt() {
        guard let o = offer else { return }
        hide(keep: false)
        model.floatOffer(o)
    }

    /// 点了另一块屏：新窗口的场景搬过去
    private func move(_ u: String) {
        guard let o = offer else { return }
        hide(keep: false)
        model.moveOffer(o, to: u)
    }

    func hide(keep: Bool) {
        timer?.invalidate(); timer = nil
        highlight(nil)
        if keep, let o = offer { model.keepSolo(o) }
        offer = nil
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
    }

    /// 鼠标停在某一块上：屏幕上那块的位置亮起来（-1 = 多加一格：整块屏）
    private func highlight(_ slot: Int?) {
        guard let slot, let o = offer, let d = model.profile.display(uuid: o.display) else { glow?.orderOut(nil); return }
        let rect: CGRect
        if slot >= 0 {
            let fr = model.stage.frames(for: o.previous, display: o.display)
            guard fr.indices.contains(slot) else { return }
            rect = fr[slot]
        } else {
            rect = d.visible.insetBy(dx: model.stage.gap, dy: model.stage.gap)
        }
        let primaryH = NSScreen.screens.first?.frame.height ?? d.frame.height
        let ns = NSRect(x: rect.minX, y: primaryH - rect.maxY, width: rect.width, height: rect.height)
        let g = glow ?? {
            let g = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            g.level = .floating
            g.isOpaque = false
            g.backgroundColor = .clear
            g.hasShadow = false
            g.ignoresMouseEvents = true
            g.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            return g
        }()
        g.contentView = NSHostingView(rootView: GlowView(name: o.window.appName, pid: o.window.pid, replacing: slot >= 0 ? o.previous.slots[slot].flatMap { model.window($0) } : nil))
        glow = g
        g.setFrame(ns, display: true)
        if !g.isVisible { g.alphaValue = 0; g.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; g.animator().alphaValue = 1 }
    }
}

@MainActor
final class ChooserState: ObservableObject {
    @Published var offer: PlacementOffer?
    @Published var remaining: Double = 1
    @Published var hovering = false
}

struct ChooserView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: ChooserState
    var pick: (Int?) -> Void
    var stack: (Int) -> Void = { _ in }
    var keep: () -> Void
    var float: () -> Void
    var move: (String) -> Void = { _ in }
    var hover: (Int?) -> Void

    var body: some View {
        if let o = state.offer {
            let prevName = o.previousScene.flatMap { id in model.contexts.first { $0.id == id } }.map { "「\($0.emoji) \($0.name)」" } ?? "刚才这块屏"
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(nsImage: appIcon(o.window.pid)).resizable().frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("「\(o.window.appName)」单独开了一个新场景").font(.system(size: 13, weight: .bold))
                        Text(o.previous.windows.isEmpty ? "从 Dock 打开的：想放到哪块屏，点一下" : o.askScreen ? "点一块屏挪过去，或者放进\(prevName)：换掉一块，或叠在它上面" : "要放进\(prevName)吗？鼠标移到一块上：换掉它，或者叠在它上面")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { float() } label: {
                        Text("🪶 以后随手").font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                    }.buttonStyle(.plain)
                    .help("「\(o.window.appName)」以后不进场景、不再问：开了就浮在上面，切场景也不藏（访达、预览这类随开随关的适合）")
                    Button { keep() } label: {
                        HStack(spacing: 6) {
                            ZStack {
                                Circle().stroke(Color.white.opacity(0.15), lineWidth: 2.5)
                                Circle().trim(from: 0, to: state.remaining).stroke(Color.purple, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }.frame(width: 14, height: 14)
                            Text("保持单独").font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                    }.buttonStyle(.plain).help(state.hovering ? "鼠标在卡片上，倒计时暂停" : "不理它也行：几秒后自动收起，保持单独")
                }
                HStack(alignment: .center, spacing: 12) {
                    if !o.previous.windows.isEmpty {
                        MiniStage(model: model, offer: o, pick: pick, stack: stack, hover: hover)
                        if o.previous.spec.layout.slots < 4 {
                            AddCellCard(offer: o, pick: pick, hover: hover)
                        }
                    }
                    if o.askScreen {
                        if !o.previous.windows.isEmpty { Divider().frame(height: 100) }
                        ScreenRow(model: model, offer: o, move: move)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(LinearGradient(colors: [.purple.opacity(0.7), .blue.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
            .padding(8)
        }
    }
}

/// 刚才那块屏的缩略图：每一块都是一个按钮
struct MiniStage: View {
    @ObservedObject var model: AppModel
    let offer: PlacementOffer
    var pick: (Int?) -> Void
    var stack: (Int) -> Void = { _ in }
    var hover: (Int?) -> Void
    @State private var over: Int?
    /// 鼠标在「叠上去」那一半上
    @State private var overStack = false

    /// 这一格有窗口、够大，才能叠
    func stackable(_ i: Int) -> Bool {
        guard offer.previous.slots.indices.contains(i), offer.previous.slots[i] != nil, offer.previous.depth(i) < DisplayStage.maxStack - 1 else { return false }
        let fr = model.stage.frames(for: DisplayStage(spec: offer.previous.spec, slots: offer.previous.slots), display: offer.display)
        return fr.indices.contains(i) && fr[i].width >= 640 && fr[i].height >= 420
    }

    var body: some View {
        let d = model.profile.display(uuid: offer.display)
        let aspect = d.map { $0.visible.width / max($0.visible.height, 1) } ?? 1.6
        let h: CGFloat = 128, w = h * aspect
        let k: CGFloat = 10
        let frames = StageGeometry.frames(offer.previous.spec, in: CGRect(x: 0, y: 0, width: w * k, height: h * k), gap: 50)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35))
            ForEach(Array(frames.enumerated()), id: \.offset) { i, f in
                let occupant = offer.previous.slots.indices.contains(i) ? offer.previous.slots[i].flatMap { model.window($0) } : nil
                let on = over == i
                Button { if overStack && stackable(i) { stack(i) } else { pick(i) } } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(on ? Color.purple.opacity(0.55) : Color.white.opacity(0.08))
                    if let t = occupant.flatMap({ model.thumbs[$0.id] }), !on {
                        Image(nsImage: t).resizable().aspectRatio(contentMode: .fill).frame(width: f.width / k, height: f.height / k).clipped().opacity(0.55)
                    }
                    VStack(spacing: 3) {
                        if on && stackable(i) {
                            // 上半：换掉；下半：叠上去
                            VStack(spacing: 2) {
                                Text("换掉它").font(.system(size: 10, weight: .bold))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(overStack ? Color.white.opacity(0.08) : Color.purple))
                                Label("叠在上面", systemImage: "square.stack.3d.up.fill").font(.system(size: 10, weight: .bold))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(overStack ? Color.purple : Color.white.opacity(0.08)))
                                    .contentShape(Rectangle())
                                    .onHover { overStack = $0 }
                            }.padding(3)
                        } else if on {
                            Image(nsImage: appIcon(offer.window.pid)).resizable().frame(width: 22, height: 22)
                            Text("换进这里").font(.system(size: 10, weight: .bold))
                        } else if let occ = occupant {
                            Image(nsImage: appIcon(occ.pid)).resizable().frame(width: 20, height: 20)
                            Text(occ.appName).font(.system(size: 9, weight: .medium)).lineLimit(1)
                        } else {
                            Image(systemName: "plus").font(.system(size: 14, weight: .light))
                            Text("空格子").font(.system(size: 9))
                        }
                    }
                    .foregroundStyle(.white)
                }
                .frame(width: f.width / k, height: f.height / k)
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? Color.purple : .clear, lineWidth: 2))
                .scaleEffect(on ? 1.03 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: on)
                .onHover { inside in
                    if inside { over = i; hover(i) } else if over == i { over = nil; overStack = false; hover(nil) }
                }
                .offset(x: f.minX / k, y: f.minY / k)
            }
        }
        .frame(width: w, height: h)
    }
}

/// 「多加一格」：左右 → 一主两辅 → 四宫格
struct AddCellCard: View {
    let offer: PlacementOffer
    var pick: (Int?) -> Void
    var hover: (Int?) -> Void
    @State private var on = false

    var body: some View {
        let next: StageLayout = switch offer.previous.spec.layout {
        case .focus, .full: .split
        case .split: .mainStack
        default: .quad
        }
        Button { pick(nil) } label: {
        VStack(spacing: 6) {
            LayoutIcon(spec: StageSpec(next), selected: on, size: CGSize(width: 48, height: 32))
            Text("多加一格").font(.system(size: 11, weight: .semibold))
            Text("→ \(next.title)").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(width: 96, height: 128)
        .background(RoundedRectangle(cornerRadius: 10).fill(on ? Color.purple.opacity(0.35) : Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(on ? 0.4 : 0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in on = inside; hover(inside ? -1 : nil) }
    }
}

/// 屏幕上要放进去的那一块：发光的紫框
struct GlowView: View {
    let name: String
    let pid: Int32
    let replacing: WindowInfo?
    @State private var pulse = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color.purple.opacity(0.16))
            RoundedRectangle(cornerRadius: 14).strokeBorder(Color.purple, lineWidth: 3)
                .shadow(color: .purple, radius: pulse ? 18 : 6)
            VStack(spacing: 10) {
                Image(nsImage: appIcon(pid)).resizable().frame(width: 56, height: 56).shadow(radius: 8)
                Text(replacing.map { "「\(name)」换掉「\($0.appName)」" } ?? "「\(name)」放这里").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true } }
    }
}

/// 不抢焦点的浮层里，第一下点击也要算数（默认第一下只是「激活窗口」，按钮不响应）
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}


/// 点 Dock 开的窗口：几块屏按真实的相对位置画出来，点哪块就放到哪块
struct ScreenRow: View {
    @ObservedObject var model: AppModel
    let offer: PlacementOffer
    var move: (String) -> Void
    @State private var over: String?

    var body: some View {
        let ds = model.profile.displays
        let all = ds.reduce(CGRect.null) { $0.union($1.frame) }
        let k = min(220 / max(all.width, 1), 118 / max(all.height, 1))
        VStack(alignment: .leading, spacing: 6) {
            Text("放到哪块屏").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                ForEach(ds, id: \.uuid) { d in
                    let here = d.uuid == offer.display
                    let on = over == d.uuid
                    Button { if !here { move(d.uuid) } } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6).fill(here ? Color.purple.opacity(0.45) : on ? Color.purple.opacity(0.3) : Color.white.opacity(0.08))
                            VStack(spacing: 2) {
                                if here { Image(nsImage: appIcon(offer.window.pid)).resizable().frame(width: 18, height: 18) }
                                Text(model.role(of: d.uuid).map(DisplayProfile.roleName) ?? d.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                                Text(here ? "现在在这" : "放这里").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: d.frame.width * k - 4, height: d.frame.height * k - 4)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(here || on ? Color.purple : Color.white.opacity(0.2), lineWidth: here || on ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in if inside { over = d.uuid } else if over == d.uuid { over = nil } }
                    .offset(x: (d.frame.minX - all.minX) * k + 2, y: (d.frame.minY - all.minY) * k + 2)
                }
            }
            .frame(width: all.width * k, height: all.height * k, alignment: .topLeading)
        }
    }
}
