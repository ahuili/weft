import AppKit
import Carbon
import SwiftUI
import WeftCore

/// 总控：双击 ⌥ 打开。一个面板里完成「找、去、整理」。
struct HubSection: Identifiable {
    var id: String
    var title: String
    var emoji: String
    var color: Color
    var context: WorkContext?
    var windows: [WindowInfo]
    var numbered = false
    var proposalReason: String? = nil
}

struct HubItem: Hashable { var section: String; var window: UInt32 }

@MainActor
final class HubState: ObservableObject {
    @Published var query = ""
    @Published var sections: [HubSection] = []
    @Published var selected: HubItem?
    var flat: [HubItem] = []
    var columns = 4

    func rebuild(_ m: AppModel) {
        var out: [HubSection] = []
        let q = query.trimmingCharacters(in: .whitespaces)
        let stashedIDs = Set(m.stashed.filter(\.isManual).map(\.windowID))
        if !q.isEmpty {
            out.append(HubSection(id: "search", title: "搜索结果", emoji: "🔎", color: .accentColor,
                                  windows: Array(FuzzyMatcher.rank(m.windows, query: q).prefix(24)), numbered: true))
        } else {
            let pred = m.predicted(5)
            if !pred.isEmpty {
                out.append(HubSection(id: "pred", title: "接下来可能要去", emoji: "✨", color: .accentColor, windows: pred, numbered: true))
            }
            var used = Set<UInt32>()
            for c in m.contexts {
                let ws = m.resolved(c)
                guard !ws.isEmpty else { continue }
                used.formUnion(ws.map(\.id))
                out.append(HubSection(id: "ctx-\(c.id)", title: c.name, emoji: c.emoji, color: m.color(c.color), context: c, windows: ws))
            }
            let rest = m.windows.filter { !used.contains($0.id) && !stashedIDs.contains($0.id) }
                .sorted { ($0.appName, $0.zIndex) < ($1.appName, $1.zIndex) }
            if !rest.isEmpty {
                out.append(HubSection(id: "rest", title: m.contexts.isEmpty ? "所有窗口" : "其他窗口", emoji: "🪟", color: .gray, windows: rest))
            }
            let st = m.windows.filter { stashedIDs.contains($0.id) && !used.contains($0.id) }
            if !st.isEmpty { out.append(HubSection(id: "stash", title: "已停靠", emoji: "🅿️", color: .gray, windows: st)) }
        }
        sections = out
        flat = out.flatMap { s in s.windows.map { HubItem(section: s.id, window: $0.id) } }
        if selected == nil || !flat.contains(selected!) { selected = flat.first }
    }

    func move(_ d: Int) {
        guard !flat.isEmpty else { return }
        let i = selected.flatMap { flat.firstIndex(of: $0) } ?? 0
        selected = flat[max(0, min(flat.count - 1, i + d))]
    }
}

struct HubView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: HubState
    var close: () -> Void
    var activate: (WindowInfo) -> Void
    @FocusState private var searchFocused: Bool
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).contentShape(Rectangle()).onTapGesture { close() }
            VStack(spacing: 16) {
                header
                if model.settings.slotModifier != .off {
                    HStack(spacing: 10) {
                        SlotBar(model: model, after: close)
                        Text("选中窗口后按 \(model.slotKey)⇧数字 钉住").font(.system(size: 11)).foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
                if model.stageActive {
                    HStack(spacing: 14) {
                        Image(systemName: "theatermasks.fill").foregroundStyle(.purple)
                        Text("舞台模式").font(.system(size: 13, weight: .bold))
                        StageBar(model: model)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
                }
                if model.aiMessage != nil && !model.tidyVisible { aiBanner }
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 26) {
                            ForEach(state.sections) { section in sectionView(section) }
                            if state.sections.isEmpty {
                                Text(model.windows.isEmpty ? "还没读到窗口：请先在引导页授予辅助功能权限" : "没有匹配的窗口")
                                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 60)
                            }
                        }.padding(.vertical, 10).padding(.horizontal, 6)
                    }
                    .onChange(of: state.selected) { _, s in
                        if let s { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(s, anchor: .center) } }
                    }
                }
                footer
            }
            .frame(maxWidth: 1260)
            .padding(.horizontal, 48).padding(.vertical, 36)
            .scaleEffect(appeared ? 1 : 0.97)
            .opacity(appeared ? 1 : 0)
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
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { appeared = true }
        }
        .onChange(of: state.query) { _, _ in state.rebuild(model) }
        .onChange(of: model.contexts) { _, _ in withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { state.rebuild(model) } }
    }

    var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
                TextField("去哪个窗口？输入名字或拼音，如 wx、gh pr、lq", text: $state.query)
                    .textFieldStyle(.plain).font(.system(size: 22)).focused($searchFocused)
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))

            Button { model.tidy() } label: {
                Label("整理桌面", systemImage: "wand.and.rays")
                    .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
            }.buttonStyle(.plain).help("⌘K：看所有桌面、删空桌面、AI 整理成场景、清理空窗口和重复窗口")

            Button { model.arrange() } label: {
                Label("排布建议", systemImage: "sparkles")
                    .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .foregroundStyle(.white)
            }.buttonStyle(.plain).help("⌘J：AI 按你的窗口、屏幕和习惯给出几套摆放方案")

            Button { model.toggleStage() } label: {
                Label(model.stageActive ? "退出舞台" : "舞台", systemImage: "theatermasks")
                    .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(model.stageActive ? AnyShapeStyle(Color.purple.opacity(0.5)) : AnyShapeStyle(.ultraThinMaterial)))
            }.buttonStyle(.plain).help("⌘E：只留现在要用的窗口，其余退到后台")

            Menu {
                Button("保存当前布局（这组显示器）") { _ = model.engine.saveManual(); Toast.show("📐 已保存布局") }
                Button("恢复布局") { let n = model.engine.restore(); Toast.show(n > 0 ? "已恢复 \(n) 个窗口" : "这组显示器还没保存过布局") }
                Divider()
                Button("撤销上一步  ⌘Z") { model.undo() }
                Divider()
                Button("设置…") { close(); NotificationCenter.default.post(name: .init("WeftOpenSettings"), object: nil) }
            } label: {
                Image(systemName: "rectangle.3.group").font(.system(size: 16, weight: .semibold))
                    .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    @ViewBuilder var aiBanner: some View {
        HStack(spacing: 12) {
            if model.organizing {
                ProgressView().controlSize(.small)
                Text("AI 正在根据窗口标题和你的切换习惯归类…（\(model.modelLabel())）").foregroundStyle(.secondary)
            } else if let msg = model.aiMessage {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(msg).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("知道了") { model.aiMessage = nil }
            }
            if model.organizing { Spacer() }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    func sectionView(_ s: HubSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 4, height: 18)
                Text("\(s.emoji)  \(s.title)").font(.system(size: 16, weight: .bold))
                Text("\(s.windows.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(.white.opacity(0.08)))
                if let r = s.proposalReason, !r.isEmpty { Text(r).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if let c = s.context {
                    if let plan = c.plan {
                        ForEach(Array(plan.enumerated()), id: \.offset) { _, pl in LayoutIcon(spec: pl.spec, size: CGSize(width: 24, height: 16)) }
                    }
                    Button { close(); model.enter(c) } label: { Label(c.plan != nil ? "摆出来" : "进入", systemImage: "arrow.right.circle") }
                        .help("把这件事的所有窗口带到最前（有记住的摆放就按摆放排好）")
                    Button { close(); model.enter(c, focusMode: true) } label: { Label("专注", systemImage: "scope") }
                        .help("进入并最小化其他所有窗口")
                    Menu {
                        Button("记住当前摆放") { model.rememberLayout(c) }
                        Button("删除这件事", role: .destructive) { model.delete(c); state.rebuild(model) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            .buttonStyle(.borderless)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 232, maximum: 232), spacing: 22, alignment: .topLeading)],
                      alignment: .leading, spacing: 20) {
                ForEach(Array(s.windows.enumerated()), id: \.element.id) { idx, w in
                    let item = HubItem(section: s.id, window: w.id)
                    WindowCard(window: w, thumb: model.thumbs[w.id], selected: state.selected == item,
                               accent: s.color == .gray ? .accentColor : s.color,
                               badge: s.numbered && idx < 9 ? "\(idx + 1)" : nil,
                               subtitle: subtitle(w), flags: flags(w))
                        .id(item)
                        .onHover { if $0 { state.selected = item } }
                        .onTapGesture { activate(w) }
                        .contextMenu { cardMenu(w) }
                }
            }
        }
    }

    func subtitle(_ w: WindowInfo) -> String {
        var parts = [w.appName]
        if let l = model.labels[w.id] { parts.append(l) }
        if model.profile.displays.count > 1, let d = model.profile.display(uuid: w.displayUUID) { parts.append(d.isBuiltin ? "笔记本屏" : d.name) }
        if let last = model.habits.lastFocused(w), last > .distantPast {
            let m = Date().timeIntervalSince(last) / 60
            parts.append(m < 1 ? "刚刚" : m < 60 ? "\(Int(m)) 分钟前" : m < 1440 ? "\(Int(m / 60)) 小时前" : "\(Int(m / 1440)) 天前")
        }
        return parts.joined(separator: " · ")
    }

    func flags(_ w: WindowInfo) -> [String] {
        var f: [String] = []
        if let s = model.slotLabel(w.id) { f.append(s) }
        if model.isPinned(w) { f.append("📌") }
        if model.stageActive && model.stage.isOnStage(w.id) { f.append("🎭 台上") }
        else if model.isManuallyStashed(w.id) { f.append("🅿️") }
        else if model.stash.isStashed(w.id) { f.append("后台") }
        if model.isFloating(w.bundleID) { f.append("🪶 随手") }
        if w.isMinimized { f.append("最小化") }
        if !w.axAvailable { f.append("其他桌面") }
        return f
    }

    @ViewBuilder func cardMenu(_ w: WindowInfo) -> some View {
        Button(model.isPinned(w) ? "从侧边栏取消固定" : "📌 固定到侧边栏  ⌘P") { model.togglePin(w); state.rebuild(model) }
        Button(model.isManuallyStashed(w.id) ? "取消停靠" : "🅿️ 停靠（挪开，缩略图留在侧边栏）  ⌘S") { model.toggleStash(w); state.rebuild(model) }
        SlotMenu(model: model, window: w)
        Button(model.isFloating(w.bundleID) ? "🪶 \(w.appName) 不再随手（又能进场景）" : "🪶 \(w.appName) 设成随手窗口（不进场景、切场景不藏）") {
            model.setFloating(w.bundleID, !model.isFloating(w.bundleID)); state.rebuild(model)
        }
        Divider()
        Button(model.stageActive ? "放到主位  ⌘←" : "左半屏  ⌘←") { close(); model.place(w, slot: 0) }
        Button(model.stageActive ? "放到副位  ⌘→" : "右半屏  ⌘→") { close(); model.place(w, slot: 1) }
        if !model.stageActive { Button("最大化  ⌘↑") { close(); model.snap(w, .maximize) } }
        if !model.contexts.isEmpty {
            Divider()
            Menu("加入事情") {
                ForEach(model.contexts) { c in Button("\(c.emoji) \(c.name)") { model.add(w, to: c); state.rebuild(model) } }
            }
            if let c = model.context(of: w) { Button("从「\(c.name)」移除") { model.remove(w, from: c); state.rebuild(model) } }
        }
    }

    static let hints: [[String]] = [["↩", "切换 / 上台"], ["1-5", "直达推荐"], ["⌘↩", "整件事"], ["⌘← ⌘→", "放左 / 放右"],
                                    ["⌘E", "舞台"], ["⌘J", "排布建议"], ["⌘K", "整理桌面"], ["⌘I", "AI 场景"], ["⌘P", "固定"], ["⌘S", "停靠"], ["⌘Z", "撤销"], ["esc", "关闭"]]

    var footer: some View {
        HStack(spacing: 18) {
            ForEach(Self.hints, id: \.self) { pair in
                let k = pair[0], v = pair[1]
                HStack(spacing: 5) {
                    Text(k).font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)))
                    Text(v).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
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
        state.query = ""
        state.selected = nil
        state.rebuild(model)
        let p = KeyPanel.make()
        p.delegate = self
        let root = ZStack {
            Glass(material: .fullScreenUI).ignoresSafeArea()
            HubView(model: model, state: state, close: { [weak self] in self?.hide() },
                    activate: { [weak self] w in self?.hide(); self?.model.focus(w) })
        }
        p.contentView = NSHostingView(rootView: root)
        p.setFrame(screen.frame, display: true)
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.16; p.animator().alphaValue = 1 }
        panel = p
        let usable: CGFloat = min(screen.frame.width - 96, 1260) + 22
        state.columns = max(1, Int(usable / 254))
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

    var selectedWindow: WindowInfo? { state.selected.flatMap { model.window($0.window) } }

    private func handle(_ e: NSEvent) -> NSEvent? {
        let cmd = e.modifierFlags.contains(.command)
        switch Int(e.keyCode) {
        case kVK_Escape:
            if model.tidyVisible { model.tidyVisible = false }
            else if model.arrangeVisible { model.arrangeVisible = false }
            else if !state.query.isEmpty { state.query = "" }
            else { hide() }
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if model.tidyVisible { model.runTidy(); state.rebuild(model); return nil }
            guard let w = selectedWindow else { return nil }
            if cmd, let sec = state.sections.first(where: { $0.id == state.selected?.section }), let c = sec.context ?? model.context(of: w) {
                hide(); model.enter(c)
            } else { hide(); model.focus(w) }
            return nil
        case kVK_LeftArrow:
            if cmd, let w = selectedWindow { hide(); model.place(w, slot: 0); return nil }
            if state.query.isEmpty { state.move(-1); return nil }
            return e
        case kVK_RightArrow:
            if cmd, let w = selectedWindow { hide(); model.place(w, slot: 1); return nil }
            if state.query.isEmpty { state.move(1); return nil }
            return e
        case kVK_UpArrow:
            if cmd, let w = selectedWindow { hide(); model.snap(w, .maximize); return nil }
            state.move(-state.columns); return nil
        case kVK_DownArrow: state.move(state.columns); return nil
        case kVK_Tab: state.move(e.modifierFlags.contains(.shift) ? -1 : 1); return nil
        default: break
        }
        if cmd, let ch = e.charactersIgnoringModifiers?.lowercased() {
            switch ch {
            case "p": if let w = selectedWindow { model.togglePin(w); state.rebuild(model) }; return nil
            case "s": if let w = selectedWindow { model.toggleStash(w); state.rebuild(model) }; return nil
            case "i": model.tidy(); model.organize(); return nil
            case "j": model.arrange(); return nil
            case "k": model.tidy(); return nil
            case "e": model.toggleStage(); state.rebuild(model); return nil
            case "z": model.undo(); return nil
            default: break
            }
        }
        // 搜索框为空时，数字键直达「接下来可能要去」
        if state.query.isEmpty, !cmd, let ch = e.characters, let n = Int(ch), n >= 1, n <= 9,
           let sec = state.sections.first(where: { $0.numbered }), n <= sec.windows.count {
            let w = sec.windows[n - 1]
            hide(); model.focus(w)
            return nil
        }
        return e
    }
}
