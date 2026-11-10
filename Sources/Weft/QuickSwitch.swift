import AppKit
import Carbon
import SwiftUI
import WeftCore

/// ⌥Tab。
/// 舞台模式下切的是「现在看不见的东西」，离你最近的排最前：先是这块屏上压在下面的窗口（一摞里翻），
/// 然后是这块屏别的场景（按最近用过的顺序，不是按位置）。⌘Tab 管 App，⌃← → 按位置挨个走场景，三个不重复。
/// 没开舞台 / 既没叠放也没别的场景时，还是老样子：按窗口切，顺序来自你真实的使用顺序。
enum FlowItem: Identifiable {
    /// current = 现在最上面那个（排第一张，只是让你知道从哪儿出发）
    case window(WindowInfo, current: Bool)
    case scene(WorkContext, current: Bool)

    var id: String {
        switch self {
        case .window(let w, _): return "w\(w.id)"
        case .scene(let c, _): return "s\(c.id)"
        }
    }
    var isScene: Bool { if case .scene = self { return true }; return false }
}

@MainActor
final class FlowState: ObservableObject {
    @Published var items: [FlowItem] = []
    @Published var index = 0
    var display = ""
}

/// 立体展开的一排卡片（和 ⌥ + 滚轮翻一摞是同一个样子）：选中的正对着你，两边的往后斜
struct FlowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: FlowState

    var body: some View {
        let d = model.profile.display(uuid: state.display)
        let aspect = d.map { $0.visible.width / max($0.visible.height, 1) } ?? 1.6
        let piles = state.items.filter { !$0.isScene }.count, scenes = state.items.count - piles
        let onScene = state.items.indices.contains(state.index) && state.items[state.index].isScene
        GeometryReader { g in
            let ch = g.size.height - 150, cw = min(ch * aspect, g.size.width * 0.5)
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    if piles > 1 { tab("这一摞", piles - 1, on: !onScene) }
                    if scenes > 0 { tab("场景 · 最近用过的在前", piles > 0 ? scenes : scenes - 1, on: onScene) }
                }
                ZStack {
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { i, it in
                        let off = Double(i - state.index)
                        card(it, CGSize(width: cw, height: cw / aspect), selected: off == 0)
                            .rotation3DEffect(.degrees(off == 0 ? 0 : (off > 0 ? -48 : 48)), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                            .scaleEffect(off == 0 ? 1 : 0.76)
                            .offset(x: off == 0 ? 0 : (off > 0 ? 1 : -1) * (cw * 0.44 + CGFloat(abs(off) - 1) * cw * 0.17))
                            .opacity(abs(off) > 3 ? 0 : 1)
                            .zIndex(10 - abs(off))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("按住 ⌥ 连按 Tab 往后 · ⇧Tab 往前 · 松开就过去 · Esc 不换").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.vertical, 16)
            .frame(width: g.size.width, height: g.size.height)
        }
        .background(RoundedRectangle(cornerRadius: 26).fill(.ultraThinMaterial))
        .background(RoundedRectangle(cornerRadius: 26).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.12)))
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.index)
    }

    func tab(_ t: String, _ n: Int, on: Bool) -> some View {
        Text("\(t)  \(n)").font(.system(size: 11, weight: on ? .bold : .regular)).foregroundStyle(.white.opacity(on ? 1 : 0.55))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(on ? Color.purple.opacity(0.55) : Color.white.opacity(0.08)))
    }

    @ViewBuilder func card(_ it: FlowItem, _ size: CGSize, selected: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.45))
                switch it {
                case .window(let w, _):
                    if let t = model.thumbs[w.id] {
                        Image(nsImage: t).resizable().aspectRatio(contentMode: .fit).frame(width: size.width, height: size.height)
                    } else {
                        Image(nsImage: appIcon(w.pid)).resizable().frame(width: 72, height: 72).frame(width: size.width, height: size.height)
                    }
                case .scene(let c, _):
                    ScenePreview(model: model, scene: c, size: size)
                }
                if case .window(_, true) = it { badge("现在最上面") }
                if case .scene(_, true) = it { badge("现在这个") }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.purple : .white.opacity(0.15), lineWidth: selected ? 3 : 1))
            .shadow(color: .black.opacity(0.5), radius: selected ? 24 : 10, y: 8)
            HStack(spacing: 6) {
                switch it {
                case .window(let w, _):
                    Image(nsImage: appIcon(w.pid)).resizable().frame(width: 18, height: 18)
                    Text(w.title.isEmpty ? w.appName : w.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                case .scene(let c, _):
                    Text(c.emoji).font(.system(size: 14))
                    Text(c.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
            }
            .foregroundStyle(.white).opacity(selected ? 1 : 0.6).frame(width: size.width)
        }
    }

    func badge(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.green.opacity(0.85))).padding(7)
    }
}

/// 没开舞台时的 ⌥Tab：和 ⌘Tab 一样的手感，但按「窗口」而不是按「App」。
@MainActor
final class QuickSwitchState: ObservableObject {
    @Published var items: [WindowInfo] = []
    @Published var index = 0
}

struct QuickSwitchView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: QuickSwitchState

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                ForEach(Array(state.items.enumerated()), id: \.element.id) { i, w in
                    WindowCard(window: w, thumb: model.thumbs[w.id], selected: i == state.index,
                               accent: .accentColor, subtitle: w.appName, width: 196)
                }
            }
            if state.items.indices.contains(state.index) {
                let w = state.items[state.index]
                HStack(spacing: 8) {
                    Text(w.title.isEmpty ? w.appName : w.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if let l = model.labels[w.id] { Text(l).font(.system(size: 12)).foregroundStyle(.secondary) }
                    if let s = model.slotLabel(w.id) {
                        Text("下次直接 \(s)").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.purple.opacity(0.35)))
                    }
                    if model.stageActive {
                        Text(model.stage.isOnStage(w.id) ? "台上" : "上台").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.purple.opacity(0.35)))
                    }
                }
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 24).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.12)))
    }
}

@MainActor
final class QuickSwitchController {
    let model: AppModel
    let state = QuickSwitchState()
    private var panel: KeyPanel?
    private var monitors: [Any] = []
    private var all: [WindowInfo] = []
    private var offset = 0
    private let visible = 7
    /// 按住的修饰键（默认 ⌥），松开即切换
    private var hold: NSEvent.ModifierFlags = .option
    /// 这次是「先翻这一摞、再切场景」的那种
    let flow = FlowState()
    private var flowMode = false

    init(model: AppModel) { self.model = model }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 每次 ⌥Tab（或 ⌥⇧Tab）都会调用
    func step(_ d: Int, hold: NSEvent.ModifierFlags = .option) {
        if !isVisible { self.hold = hold.isEmpty ? .option : hold; if !openFlow() { open() }; return }
        if flowMode {
            let n = flow.items.count
            if n > 0 { flow.index = ((flow.index + d) % n + n) % n }
            return
        }
        let n = all.count
        guard n > 0 else { return }
        var global = (offset + state.index + d + n) % n
        if global < 0 { global += n }
        layout(global)
    }

    /// 舞台模式下这块屏上「看不见的东西」：压在下面的窗口（你正在用的那一格的排最前），然后是别的场景（最近用过的在前）
    func flowItems() -> [FlowItem] {
        guard model.stageActive, let u = model.stage.currentDisplay() ?? model.profile.main?.uuid, let st = model.stage.stage(for: u) else { return [] }
        let focused = model.system.focusedWindowID()
        let cur = focused.flatMap { id in st.index(of: id) ?? model.stage.stackLocate(id).flatMap { $0.display == u ? $0.slot : nil } } ?? st.active
        var order = Array(st.slots.indices)
        if let k = order.firstIndex(of: cur) { order.insert(order.remove(at: k), at: 0) }
        var under: [WindowInfo] = []
        var top: WindowInfo?
        for j in order {
            guard let t = st.slots[j], let m = st.stacks[t], !m.isEmpty else { continue }
            if top == nil { top = model.window(t) }
            under += m.reversed().compactMap { model.window($0) }
        }
        let here = model.showingScene[u].flatMap { id in model.contexts.first { $0.id == id } }.flatMap { model.isBlank($0.id) ? nil : $0 }
        let scenes = model.switcherScenes(for: u).filter { c in
            c.id != here?.id && !model.isBlank(c.id) && model.showingOn(c.id) == nil && model.sceneSlots(c).contains { $0.window?.axAvailable == true }
        }.sorted { (model.sceneUsedAt[$0.id] ?? .distantPast) > (model.sceneUsedAt[$1.id] ?? .distantPast) }
        guard !under.isEmpty || !scenes.isEmpty else { return [] }
        var out: [FlowItem] = []
        if !under.isEmpty, let top { out.append(.window(top, current: true)) } else if let here { out.append(.scene(here, current: true)) }
        out += under.map { .window($0, current: false) }
        out += scenes.map { .scene($0, current: false) }
        flow.display = u
        return out
    }

    private func openFlow() -> Bool {
        guard model.stageActive else { return false }
        model.refresh(captureThumbs: false)
        let items = flowItems()
        guard items.count > 1 || (items.count == 1 && !isCurrent(items[0])) else { return false }
        flowMode = true
        flow.items = items
        flow.index = isCurrent(items[0]) ? 1 : 0
        var ids = items.compactMap { it -> UInt32? in if case .window(let w, _) = it { return w.id }; return nil }
        ids += model.sceneWindowIDs.filter { model.thumbs[$0] == nil }
        model.thumbnails.refresh(ids, maxWidth: 700) { [weak self] new in self?.model.thumbs.merge(new) { $1 } }
        let p = KeyPanel.make(level: .popUpMenu)
        p.contentView = NSHostingView(rootView: FlowView(model: model, state: flow))
        panel = p
        if let d = model.profile.display(uuid: flow.display) {
            let primaryH = NSScreen.screens.first?.frame.height ?? d.frame.height
            let ns = NSRect(x: d.frame.minX, y: primaryH - d.frame.maxY, width: d.frame.width, height: d.frame.height)
            let w = min(ns.width - 80, 1180), h = min(ns.height - 120, 470)
            p.setFrame(NSRect(x: ns.midX - w / 2, y: ns.midY - h / 2, width: w, height: h), display: true)
        }
        p.makeKeyAndOrderFront(nil)
        installMonitors()
        if !hold.isEmpty, !NSEvent.modifierFlags.contains(hold) { commit() }
        return true
    }

    /// 调试：不用按着 ⌥ 也把卡片摆出来看看（ctl flow），再调一次 / ctl hide 收起
    func debugFlow() {
        if isVisible { close(); return }
        model.refresh(captureThumbs: false)
        hold = []
        _ = openFlow()
    }
    func debugClose() { if isVisible { close() } }

    private func isCurrent(_ it: FlowItem) -> Bool {
        switch it { case .window(_, let c): return c; case .scene(_, let c): return c }
    }

    private func installMonitors() {
        // 松开 ⌥ 即切换；esc 取消
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            self?.handle(e) ?? e
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            Task { @MainActor in _ = self?.handle(e) }
        } as Any)
    }

    private func commitFlow() {
        let it = flow.items.indices.contains(flow.index) ? flow.items[flow.index] : nil
        let u = flow.display
        close()
        switch it {
        case .window(let w, let current)?:
            if current { return }
            if model.stage.raiseInStack(w.id) { model.stageChanged(); model.syncScenes() } else { model.focus(w) }
        case .scene(let c, let current)?:
            if !current { model.switchScene(c, on: u) }
        case nil: break
        }
    }

    private func open() {
        model.refresh(captureThumbs: false)
        all = model.mruOrder()
        guard all.count > 0 else { Toast.show("没有可切换的窗口"); return }
        model.thumbnails.refresh(Array(all.prefix(12).map(\.id)), maxWidth: 400) { [weak self] new in
            self?.model.thumbs.merge(new) { $1 }
        }
        layout(all.count > 1 ? 1 : 0)
        let p = KeyPanel.make(level: .popUpMenu)
        p.contentView = NSHostingView(rootView: QuickSwitchView(model: model, state: state))
        panel = p
        resize()
        p.makeKeyAndOrderFront(nil)
        installMonitors()
        // 快速点按 ⌥Tab 时 ⌥ 可能已经松开：直接切到上一个窗口
        if !NSEvent.modifierFlags.contains(hold) { commit() }
    }

    private func layout(_ global: Int) {
        // 选中项始终在可视窗口内
        if global < offset { offset = global }
        if global >= offset + visible { offset = global - visible + 1 }
        state.items = Array(all[offset..<min(all.count, offset + visible)])
        state.index = global - offset
        resize()
    }

    private func resize() {
        guard let p = panel, let screen = mouseScreen() else { return }
        let w = CGFloat(state.items.count) * 212 + 32
        let h: CGFloat = 230
        p.setFrame(NSRect(x: screen.frame.midX - w / 2, y: screen.frame.midY - h / 2 + 60, width: w, height: h), display: true)
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        if e.type == .flagsChanged && !hold.isEmpty && !e.modifierFlags.contains(hold) { commit(); return e }
        if e.type == .keyDown {
            switch Int(e.keyCode) {
            case kVK_Escape: close(); return nil
            case kVK_Return: commit(); return nil
            case kVK_LeftArrow: step(-1); return nil
            case kVK_RightArrow: step(1); return nil
            default: return e
            }
        }
        return e
    }

    private func commit() {
        guard isVisible else { return }
        if flowMode { commitFlow(); return }
        let target = state.items.indices.contains(state.index) ? state.items[state.index] : nil
        close()
        if let target { model.focus(target) }
    }

    private func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        offset = 0
        flowMode = false
    }
}
