import AppKit
import Carbon
import SwiftUI
import WeftCore

/// 总控 = 屏幕中间的一条命令栏：打字就搜窗口、App、场景和动作；不打字时只给「接下来可能要去」和这块屏的场景。
/// （以前是一整屏的窗口墙，和调度中心重复，用的人少。）整理桌面 / 排布建议还是在这里盖一层打开。
struct BarAction: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    var key: String? = nil
    var keywords: String = ""
    /// 做完要不要收起命令栏
    var closes = true
    let run: () -> Void
}

enum BarItem: Identifiable {
    case window(WindowInfo)
    case app(AppEntry)
    case scene(WorkContext, current: Bool)
    case action(BarAction)

    var id: String {
        switch self {
        case .window(let w): return "w\(w.id)"
        case .app(let a): return "a\(a.id)"
        case .scene(let c, _): return "s\(c.id)"
        case .action(let a): return "x\(a.id)"
        }
    }
}

struct BarGroup: Identifiable {
    let id: String
    let title: String
    var items: [BarItem]
    var numbered = false
}

@MainActor
final class HubState: ObservableObject {
    @Published var query = ""
    @Published var groups: [BarGroup] = []
    @Published var selected: String?
    var flat: [BarItem] = []
    /// 命令栏开在哪块屏（场景切到这块屏）
    var display = ""
    var close: () -> Void = {}

    func rebuild(_ m: AppModel) {
        let q = query.trimmingCharacters(in: .whitespaces)
        let acts = actions(m)
        let scenes = m.switcherScenes(for: display).filter { !m.sceneDormant($0) && !m.isBlank($0.id) }
        var out: [BarGroup] = []
        if q.isEmpty {
            let pred = m.predicted(5)
            if !pred.isEmpty { out.append(BarGroup(id: "next", title: "接下来可能要去", items: pred.map { .window($0) }, numbered: true)) }
            if !scenes.isEmpty {
                out.append(BarGroup(id: "scenes", title: "这块屏的场景", items: scenes.map { .scene($0, current: m.showingScene[display] == $0.id) }))
            }
            out.append(BarGroup(id: "actions", title: "动作", items: acts.map { .action($0) }))
        } else {
            let ws = Array(FuzzyMatcher.rank(m.windows, query: q).prefix(8))
            if !ws.isEmpty { out.append(BarGroup(id: "windows", title: "窗口", items: ws.map { .window($0) })) }
            let sc = m.scenes.compactMap { c in FuzzyMatcher.score(query: q, candidates: [c.name]).map { (c, $0) } }.sorted { $0.1 > $1.1 }.prefix(4)
            if !sc.isEmpty { out.append(BarGroup(id: "scenes", title: "场景", items: sc.map { .scene($0.0, current: m.showingOn($0.0.id) != nil) })) }
            let apps = AppCatalog.shared.search(q, windows: m.windows, limit: 4)
            if !apps.isEmpty { out.append(BarGroup(id: "apps", title: "App（现在没有窗口）", items: apps.map { .app($0) })) }
            let ac = acts.compactMap { a in FuzzyMatcher.score(query: q, candidates: [a.title, a.keywords]).map { (a, $0) } }.sorted { $0.1 > $1.1 }.prefix(5)
            if !ac.isEmpty { out.append(BarGroup(id: "actions", title: "动作", items: ac.map { .action($0.0) })) }
        }
        groups = out
        flat = out.flatMap(\.items)
        if selected == nil || !flat.contains(where: { $0.id == selected }) { selected = flat.first?.id }
    }

    func move(_ d: Int) {
        guard !flat.isEmpty else { return }
        let i = flat.firstIndex { $0.id == selected } ?? 0
        selected = flat[(i + d + flat.count) % flat.count].id
    }

    var selectedItem: BarItem? { flat.first { $0.id == selected } }

    func actions(_ m: AppModel) -> [BarAction] {
        let u = display
        let post = { (name: String) in NotificationCenter.default.post(name: .init(name), object: nil) }
        var a: [BarAction] = []
        a.append(BarAction(id: "blank", title: "空桌面", detail: "这块屏清空（现在的场景原样留着），马上挑一个窗口放进来", symbol: "macwindow.badge.plus", key: "⌘N",
                           keywords: "new desk blank empty kong xinjian 新建 新场景 空 桌面") { m.newDesk(on: u.isEmpty ? nil : u) })
        if m.stageActive {
            a.append(BarAction(id: "layout", title: "换版式…", detail: "这块屏分成 1~4 格，空格子里直接挑窗口", symbol: "rectangle.split.2x1", keywords: "layout banshi 版式 分屏 格子") { post("WeftOpenLayoutPicker") })
            a.append(BarAction(id: "save", title: "把这块屏存成场景", detail: "现在的窗口和版式记下来，以后一键摆回来", symbol: "square.and.arrow.down", keywords: "save scene baocun 保存 场景") {
                if let c = m.saveScene(from: u) { Toast.show("🎬 已存成场景「\(c.name)」· 场景工作台里可以改名", seconds: 2.2) }
            })
        }
        a.append(BarAction(id: "tidy", title: "整理桌面", detail: "删空桌面、清理空窗口和重复窗口、AI 归成场景", symbol: "wand.and.rays", key: "⌘K", keywords: "tidy zhengli clean 清理", closes: false) { m.tidy() })
        a.append(BarAction(id: "arrange", title: "排布建议", detail: "AI 按你的窗口、屏幕和习惯给几套摆法", symbol: "sparkles", key: "⌘J", keywords: "arrange paibu ai 摆放", closes: false) { m.arrange() })
        a.append(BarAction(id: "studio", title: "场景工作台", detail: "建场景、改场景、绑定另一块屏", symbol: "square.grid.2x2", keywords: "studio scene changjing 编辑") { post("WeftOpenStudio") })
        if m.stageActive {
            a.append(BarAction(id: "heal", title: "归位", detail: "乱了就用：每个窗口回自己的格子", symbol: "arrow.triangle.2.circlepath", keywords: "heal guiwei reset 复位") { m.healStage() })
        }
        a.append(BarAction(id: "later", title: "当前窗口稍后处理", detail: "先退到后台，记在侧栏的「稍后处理」里", symbol: "hourglass", keywords: "later shaohou stash 停靠 待办") { m.stashFocused() })
        a.append(BarAction(id: "stage", title: m.stageActive ? "退出舞台模式" : "进入舞台模式", detail: m.stageActive ? "所有窗口回到原来的位置" : "只留现在要用的窗口，其余退到后台",
                           symbol: "theatermasks", key: "⌘E", keywords: "stage wutai exit quit 退出 舞台") { m.toggleStage() })
        a.append(BarAction(id: "undo", title: "撤销上一步", detail: "", symbol: "arrow.uturn.backward", key: "⌘Z", keywords: "undo chexiao") { m.stageActive ? m.undoStage() : m.undo() })
        a.append(BarAction(id: "keys", title: "快捷键速查", detail: "", symbol: "keyboard", key: "?", keywords: "keys shortcut help kuaijiejian 帮助") { post("WeftOpenCheatSheet") })
        a.append(BarAction(id: "settings", title: "设置…", detail: "", symbol: "gearshape", keywords: "settings preferences shezhi") { post("WeftOpenSettings") })
        return a
    }
}

struct HubView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: HubState
    var close: () -> Void
    var run: (BarItem) -> Void
    @FocusState private var searchFocused: Bool
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.16).contentShape(Rectangle()).onTapGesture { close() }
            GeometryReader { g in
                VStack(spacing: 10) {
                    bar
                    if model.organizing || (model.aiMessage != nil && !model.tidyVisible) { aiBanner }
                }
                .frame(width: min(700, g.size.width - 80))
                .frame(maxWidth: .infinity)
                .padding(.top, max(60, g.size.height * 0.16))
                .scaleEffect(appeared ? 1 : 0.97, anchor: .top)
                .opacity(appeared ? 1 : 0)
            }
            if model.arrangeVisible {
                Color.black.opacity(0.3).contentShape(Rectangle()).onTapGesture { model.arrangeVisible = false }
                ArrangeSheet(model: model, close: close).frame(maxWidth: 1200).padding(60)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            if model.tidyVisible {
                Color.black.opacity(0.3).contentShape(Rectangle()).onTapGesture { model.tidyVisible = false }
                TidySheet(model: model).padding(60)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.arrangeVisible)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.tidyVisible)
        .onAppear {
            searchFocused = true
            withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) { appeared = true }
        }
        .onChange(of: state.query) { _, _ in state.rebuild(model) }
        .onChange(of: model.contexts) { _, _ in state.rebuild(model) }
    }

    var bar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .medium)).foregroundStyle(.secondary)
                TextField("找窗口、App、场景，或者要做的事（支持拼音：wx、zl）", text: $state.query)
                    .textFieldStyle(.plain).font(.system(size: 20)).focused($searchFocused)
                if model.stageActive {
                    Text("🎭 舞台").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.purple.opacity(0.25)))
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().opacity(0.5)
            HStack(alignment: .top, spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(state.groups) { g in
                                Text(g.title).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                                ForEach(Array(g.items.enumerated()), id: \.element.id) { i, it in
                                    BarRow(model: model, item: it, selected: state.selected == it.id, number: g.numbered ? i + 1 : nil)
                                        .id(it.id)
                                        .onHover { if $0 { state.selected = it.id } }
                                        .onTapGesture { run(it) }
                                        .contextMenu { if case .window(let w) = it { WindowMenu(model: model, window: w) } }
                                }
                            }
                            if state.flat.isEmpty {
                                Text(model.windows.isEmpty ? "还没读到窗口：请先在引导页授予辅助功能权限" : "没有匹配的结果")
                                    .font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 28)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: state.selected) { _, s in if let s { proxy.scrollTo(s) } }
                }
                // 选中的是窗口：右边给一张大一点的预览，几个 Chrome 窗口也分得清
                if case .window(let w)? = state.selectedItem, let t = model.thumbs[w.id] {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                            .frame(width: 240, height: 150).background(Color.black.opacity(0.25))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(model.windowName(w)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        if !model.windowDetail(w).isEmpty { Text(model.windowDetail(w)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
                        if let l = model.labels[w.id] { Text(l).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    .frame(width: 240, alignment: .leading)
                    .padding(12)
                }
            }
            .frame(maxHeight: 430)
            Divider().opacity(0.5)
            HStack(spacing: 14) {
                hint("↩", "去 / 执行"); hint("↑↓", "选"); hint("⌘← ⌘→", "窗口放左 / 右格")
                if state.query.isEmpty { hint("1-5", "直达") }
                Spacer()
                hint("?", "快捷键"); hint("esc", "关闭")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(Glass(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 12)
    }

    func hint(_ k: String, _ v: String) -> some View {
        HStack(spacing: 5) {
            Text(k).font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)))
            Text(v).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var aiBanner: some View {
        HStack(spacing: 12) {
            if model.organizing {
                ProgressView().controlSize(.small)
                Text("AI 正在根据窗口标题和你的切换习惯归类…（\(model.modelLabel())）").foregroundStyle(.secondary)
                Spacer()
            } else if let msg = model.aiMessage {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(msg).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("知道了") { model.aiMessage = nil }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
    }
}

struct BarRow: View {
    @ObservedObject var model: AppModel
    let item: BarItem
    let selected: Bool
    var number: Int?

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if !detail.isEmpty { Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 6)
            if let t = trailing {
                Text(t).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.1)))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.3) : .clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder var icon: some View {
        switch item {
        case .window(let w): Image(nsImage: appIcon(w.pid)).resizable()
        case .app(let a): Image(nsImage: a.icon).resizable().opacity(a.running ? 1 : 0.7)
        case .scene(let c, _): Text(c.emoji).font(.system(size: 17))
        case .action(let a): Image(systemName: a.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    var title: String {
        switch item {
        case .window(let w): return model.windowName(w)
        case .app(let a): return a.name
        case .scene(let c, _): return c.name
        case .action(let a): return a.title
        }
    }

    var detail: String {
        switch item {
        case .window(let w):
            var p: [String] = []
            if !model.windowDetail(w).isEmpty { p.append(String(model.windowDetail(w).prefix(40))) }
            if model.stageActive { p.append(model.stage.isOnStage(w.id) ? "在台上" : "在后台") }
            if model.isManuallyStashed(w.id) { p.append("⏳ 稍后处理") }
            if let s = model.slotLabel(w.id) { p.append(s) }
            return p.joined(separator: " · ")
        case .app(let a): return a.running ? "开着，但没有窗口 · 新开一个" : "没在运行 · 打开"
        case .scene(let c, let current):
            let names = model.resolved(c).map(\.appName)
            var seen = Set<String>()
            let apps = names.filter { seen.insert($0).inserted }.prefix(4).joined(separator: " + ")
            return (current ? "现在摆着 · " : "") + apps
        case .action(let a): return a.detail
        }
    }

    var trailing: String? {
        if let number { return "\(number)" }
        switch item {
        case .action(let a): return a.key
        case .scene: return "场景"
        default: return nil
        }
    }
}

@MainActor
final class HubController: NSObject, NSWindowDelegate {
    let model: AppModel
    let state = HubState()
    private var panel: KeyPanel?
    private var monitor: Any?

    init(model: AppModel) { self.model = model }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show(arrange: Bool = false) {
        guard let screen = mouseScreen() else { return }
        if isVisible { if arrange { model.arrange() }; return }
        model.pinStageDisplay(screen)
        model.arrangeVisible = false
        model.tidyVisible = false
        model.refresh()
        state.display = model.stage.currentDisplay() ?? model.profile.main?.uuid ?? ""
        state.close = { [weak self] in self?.hide() }
        state.query = ""
        state.selected = nil
        state.rebuild(model)
        let p = KeyPanel.make()
        p.delegate = self
        p.contentView = NSHostingView(rootView: HubView(model: model, state: state, close: { [weak self] in self?.hide() },
                                                        run: { [weak self] it in self?.run(it) }))
        p.setFrame(screen.frame, display: true)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.14; p.animator().alphaValue = 1 }
        panel = p
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handle(e) ?? e }
        if arrange { model.arrange() }
    }

    func hide() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard let p = panel else { return }
        panel = nil
        model.pinStageDisplay(nil)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    /// 数字槽位「钉选中的窗口」用
    var selectedWindow: WindowInfo? {
        if case .window(let w)? = state.selectedItem { return model.window(w.id) }
        return nil
    }

    func run(_ it: BarItem) {
        switch it {
        case .window(let w): hide(); model.focus(w)
        case .app(let a): hide(); AppCatalog.open(a)
        case .scene(let c, _):
            let u = state.display
            hide()
            model.switchScene(c, on: model.showingOn(c.id) ?? (model.belongs(c, to: u) ? u : nil))
            model.launchMissing(c.id)
        case .action(let a):
            if a.closes { hide() }
            a.run()
            if !a.closes { state.rebuild(model) }
        }
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        let cmd = e.modifierFlags.contains(.command)
        let overlay = model.tidyVisible || model.arrangeVisible
        switch Int(e.keyCode) {
        case kVK_Escape:
            if model.tidyVisible { model.tidyVisible = false }
            else if model.arrangeVisible { model.arrangeVisible = false }
            else if !state.query.isEmpty { state.query = "" }
            else { hide() }
            return nil
        case kVK_ANSI_Slash where e.modifierFlags.contains(.shift) && state.query.isEmpty && !overlay:
            hide()
            NotificationCenter.default.post(name: .init("WeftOpenCheatSheet"), object: nil)
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if model.tidyVisible { model.runTidy(); state.rebuild(model); return nil }
            if overlay { return e }
            if let it = state.selectedItem { run(it) }
            return nil
        case kVK_LeftArrow:
            if cmd, let w = selectedWindow { hide(); model.place(w, slot: 0); return nil }
            return e
        case kVK_RightArrow:
            if cmd, let w = selectedWindow { hide(); model.place(w, slot: 1); return nil }
            return e
        case kVK_UpArrow: if overlay { return e }; state.move(-1); return nil
        case kVK_DownArrow: if overlay { return e }; state.move(1); return nil
        case kVK_Tab: if overlay { return e }; state.move(e.modifierFlags.contains(.shift) ? -1 : 1); return nil
        default: break
        }
        if cmd, let ch = e.charactersIgnoringModifiers?.lowercased() {
            switch ch {
            case "i": model.tidy(); model.organize(); return nil
            case "j": model.arrange(); return nil
            case "k": model.tidy(); return nil
            case "e": hide(); model.toggleStage(); return nil
            case "n": let u = state.display; hide(); model.newDesk(on: u.isEmpty ? nil : u); return nil
            case "z": model.stageActive ? model.undoStage() : model.undo(); state.rebuild(model); return nil
            default: break
            }
        }
        // 搜索框为空时，数字键直达「接下来可能要去」
        if state.query.isEmpty, !cmd, !overlay, let ch = e.characters, let n = Int(ch), n >= 1, n <= 9,
           let g = state.groups.first(where: { $0.numbered }), n <= g.items.count {
            run(g.items[n - 1])
            return nil
        }
        return e
    }
}
