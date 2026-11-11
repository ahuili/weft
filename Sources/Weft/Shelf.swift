import AppKit
import SwiftUI
import WeftCore

/// 边缘侧栏 = 「后台」：鼠标贴到屏幕边缘就滑出。
/// 一打开就能打字搜；上面是舞台控制和「事情」，下面是固定 / 推荐 / 按 App 叠放的所有窗口。
/// 悬停任何一行，旁边浮出大预览；点一下就切过去（舞台模式下 = 请上台），◧ ◨ 直接放到主位 / 副位。
@MainActor
final class ShelfState: ObservableObject {
    @Published var query = ""
    @Published var expanded: Set<String> = []
    /// 用快捷键打开的：显示数字提示，不跟着鼠标收起
    @Published var byKey = false
    /// 鼠标停在哪个窗口上（⇧数字 钉它）
    var hovered: WindowInfo?
}

struct ShelfView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: ShelfState
    var activate: (WindowInfo) -> Void
    var peek: (WindowInfo?, CGRect) -> Void
    var close: () -> Void
    /// 把一行拖出去：(窗口, 松手了没)
    var drag: (WindowInfo, Bool) -> Void = { _, _ in }
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
            search.padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if state.query.trimmingCharacters(in: .whitespaces).isEmpty { home } else { results }
                }
                // 固定宽度、靠左：哪一行万一太宽，也只会在右边被裁，不会把整列往左推出去
                .frame(width: 276, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
            footer.padding(12)
        }
        .frame(width: 300)
        .background(Glass(material: .sidebar))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
        .padding(.vertical, 8).padding(.horizontal, 6)
        .onAppear { searchFocused = true }
    }
}

/// 「此刻」：这个时间你通常在用的场景 / 常这样摆、要不要存成场景
struct MomentCard: View {
    @ObservedObject var model: AppModel
    var close: () -> Void

    var body: some View {
        let _ = model.memoryRevision
        if let m = model.moment() {
            HStack(alignment: .center, spacing: 8) {
                Text("🧠").font(.system(size: 16))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(m)).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    HStack(spacing: -3) {
                        ForEach(Array(members(m).prefix(5).enumerated()), id: \.offset) { _, b in
                            if let w = model.windows.first(where: { $0.bundleID == b }) { Image(nsImage: appIcon(w.pid)).resizable().frame(width: 16, height: 16) }
                        }
                    }
                    Text(subtitle(m)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: { act(m) }) { Text(actionTitle(m)) }.controlSize(.small)
                Button { model.dismissMoment(m) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("这周不再提这个")
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [.purple.opacity(0.18), .blue.opacity(0.10)], startPoint: .leading, endPoint: .trailing)))
        }
    }

    func title(_ m: AppModel.Moment) -> String {
        switch m {
        case .scene(_, let p), .routine(let p): return "这个时间（\(p.typicalHour) 点左右）你通常在用"
        case .save(let p): return "你常这样摆（\(p.count) 次）"
        }
    }
    func subtitle(_ m: AppModel.Moment) -> String {
        switch m {
        case .scene(let c, _): return "\(c.emoji) \(c.name)"
        case .routine(let p), .save(let p):
            return p.sample.parts.flatMap(\.members).compactMap { m in model.windows.first { $0.bundleID == m.bundleID }?.appName }.prefix(3).joined(separator: " + ")
        }
    }
    func members(_ m: AppModel.Moment) -> [String] {
        switch m {
        case .scene(_, let p), .routine(let p), .save(let p): return p.sample.parts.flatMap(\.members).map(\.bundleID)
        }
    }
    func actionTitle(_ m: AppModel.Moment) -> String {
        switch m { case .scene, .routine: return "摆出来"; case .save: return "存成场景" }
    }
    func act(_ m: AppModel.Moment) {
        switch m {
        case .scene(let c, _): close(); model.enter(c)
        case .routine(let p): close(); model.applyPattern(p)
        case .save(let p): model.savePattern(p)
        }
    }
}

// MARK: - 侧栏的各个部分

extension ShelfView {

    // MARK: 头部

    var header: some View {
        HStack(spacing: 8) {
            Text("Weft").font(.system(size: 16, weight: .heavy, design: .rounded))
            Spacer()
            Button { model.toggleStage() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "theatermasks.fill").font(.system(size: 11))
                    Text(model.stageActive ? "舞台 开" : "舞台 关").font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(model.stageActive ? AnyShapeStyle(LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(Color.white.opacity(0.1))))
                .foregroundStyle(model.stageActive ? .white : .primary)
            }
            .buttonStyle(.plain)
            .help(model.stageActive ? "退出舞台模式（\(model.settings.stageTrigger.display)）" : "舞台模式：只留你现在要用的窗口，其余退到后台（\(model.settings.stageTrigger.display)）")
        }
    }

    var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("直接打字找窗口（支持拼音）", text: $state.query)
                .textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                .onSubmit {
                    if let w = FuzzyMatcher.rank(model.windows, query: state.query).first { activate(w) }
                    else if let a = AppCatalog.shared.search(state.query, windows: model.windows).first { close(); AppCatalog.open(a) }
                }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.08)))
    }

    // MARK: 主页

    @ViewBuilder var home: some View {
        let _ = model.stageRevision
        if model.stageActive {
            ShelfStagePanel(model: model)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.10)))
        }
        sceneCards
        topApps
        if model.settings.slotModifier != .off {
            SlotBar(model: model, compact: true, after: close).frame(maxWidth: .infinity, alignment: .leading)
        }

        let onStage = model.stageActive ? model.stage.onStage : []
        let pinned = model.pinnedWindows()
        let manual = model.windows.filter { model.isManuallyStashed($0.id) }
        let manualIDs = Set(manual.map(\.id))

        later(manual)
        if !pinned.isEmpty { grid("📌 固定", pinned) }
        appGroups(model.windows.filter { !onStage.contains($0.id) && !manualIDs.contains($0.id) })
    }

    /// 这块屏的场景：点一下就切
    @ViewBuilder var sceneCards: some View {
        let u = model.stage.currentDisplay() ?? ""
        let list = model.switcherScenes(for: u).filter { !model.sceneDormant($0) }
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                title("🎬 这块屏的场景", list.count)
                VStack(spacing: 3) {
                    ForEach(list) { c in
                        let on = model.showingScene[u] == c.id
                        Button { close(); model.switchScene(c, on: u) } label: {
                            HStack(spacing: 7) {
                                Text(c.emoji).font(.system(size: 13))
                                Text(c.name).font(.system(size: 12, weight: on ? .bold : .medium)).lineLimit(1)
                                Spacer(minLength: 0)
                                HStack(spacing: -4) {
                                    ForEach(Array(model.resolved(c).prefix(4)), id: \.id) { w in
                                        Image(nsImage: appIcon(w.pid)).resizable().frame(width: 15, height: 15)
                                    }
                                }
                            }
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.purple.opacity(0.28) : Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Color.purple.opacity(0.8) : .clear, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(on ? "现在摆着的就是它" : "切到这个场景")
                    }
                }
            }
        }
    }

    /// 常用 App：按你最近的使用时间排（一周前的只算一半），不是写死的；用键盘打开侧栏时按数字直达
    @ViewBuilder var topApps: some View {
        let apps = model.topApps(6)
        if !apps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                title("⭐ 常用")
                HStack(spacing: 0) {
                    ForEach(Array(apps.enumerated()), id: \.element.id) { i, a in
                        Button { close(); model.openTopApp(a) } label: {
                            VStack(spacing: 3) {
                                Image(nsImage: a.icon).resizable().frame(width: 32, height: 32)
                                    .opacity(a.windows.isEmpty ? 0.45 : 1)
                                    .overlay(alignment: .topTrailing) {
                                        if state.byKey && model.settings.slotModifier == .off {
                                            Text("\(i + 1)").font(.system(size: 9, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                                                .frame(width: 14, height: 14).background(Circle().fill(Color.purple)).offset(x: 5, y: -4)
                                        }
                                    }
                                Circle().fill(a.onStage ? Color.purple : .clear).frame(width: 4, height: 4)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(a.windows.isEmpty ? "\(a.name)（没开着）：点一下打开" : a.onStage ? "\(a.name)：已经在台上，点一下切过去" : "\(a.name)：点一下请上台")
                    }
                }
            }
        }
    }

    /// 稍后处理：你特意放一边、等会儿要回来的窗口。点一下回到台上，也就从这里消失；把手上的小点提醒你这里还有东西
    @ViewBuilder func later(_ ws: [WindowInfo]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            title("⏳ 稍后处理", ws.isEmpty ? nil : ws.count)
            if ws.isEmpty {
                Text("等会儿要回的消息、要看的文档：右键窗口 →「稍后处理」。它先退到后台，屏幕边的把手上会亮一个点提醒你。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(ws) { w in WindowRow(model: model, window: w, showApp: true, activate: activate, peek: peek, drag: drag) }
        }
    }

    func pairCard(_ a: WindowInfo, _ b: WindowInfo) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: appIcon(a.pid)).resizable().frame(width: 18, height: 18)
            Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            Image(nsImage: appIcon(b.pid)).resizable().frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("常一起用").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Text(model.short(b)).font(.system(size: 12)).lineLimit(1)
            }
            Spacer()
            Button("并排") { close(); model.pairUp(a, b) }.controlSize(.small)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
    }

    // MARK: 分组

    func title(_ t: String, _ count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(t).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
            if let count { Text("\(count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary) }
        }
    }

    @ViewBuilder func grid(_ t: String, _ ws: [WindowInfo], empty: String? = nil) -> some View {
        if !ws.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 8) {
                title(t, ws.isEmpty ? nil : ws.count)
                if ws.isEmpty, let empty {
                    Text(empty).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: [GridItem(.fixed(132), spacing: 12), GridItem(.fixed(132))], alignment: .leading, spacing: 12) {
                    ForEach(ws) { w in MiniCard(model: model, window: w, activate: activate, peek: peek) }
                }
            }
        }
    }

    /// 按 App 叠放：一个 App 一行，多个窗口的可以展开，每个窗口带区分说明
    func appGroups(_ ws: [WindowInfo]) -> some View {
        let groups = Dictionary(grouping: ws, by: \.bundleID)
            .map { ($0.key, $0.value.sorted { $0.zIndex < $1.zIndex }) }
            .sorted { a, b in
                let ra = a.1.compactMap { model.habits.mru.firstIndex(of: $0.id) }.min() ?? 999
                let rb = b.1.compactMap { model.habits.mru.firstIndex(of: $0.id) }.min() ?? 999
                return ra != rb ? ra < rb : a.1[0].appName < b.1[0].appName
            }
        return VStack(alignment: .leading, spacing: 4) {
            title(model.stageActive ? "🎭 后台 · 按 App" : "🪟 全部窗口 · 按 App", ws.count)
            ForEach(groups, id: \.0) { bundle, list in
                if list.count == 1 {
                    WindowRow(model: model, window: list[0], showApp: true, activate: activate, peek: peek, drag: drag)
                } else {
                    let open = state.expanded.contains(bundle)
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { if open { state.expanded.remove(bundle) } else { state.expanded.insert(bundle) } }
                    } label: {
                        HStack(spacing: 8) {
                            ZStack {
                                Image(nsImage: appIcon(list[0].pid)).resizable().frame(width: 20, height: 20).offset(x: 3, y: -3).opacity(0.5)
                                Image(nsImage: appIcon(list[0].pid)).resizable().frame(width: 20, height: 20)
                            }.frame(width: 24, height: 24)
                            Text(list[0].appName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text("\(list.count) 个窗口").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if open {
                        ForEach(list) { w in
                            WindowRow(model: model, window: w, showApp: false, activate: activate, peek: peek, drag: drag).padding(.leading, 18)
                        }
                    }
                }
            }
        }
    }

    var results: some View {
        let ws = Array(FuzzyMatcher.rank(model.windows, query: state.query).prefix(20))
        return VStack(alignment: .leading, spacing: 4) {
            title("🔎 搜索结果 · ↩ 第一个 · 数字键直达", ws.count)
            let apps = AppCatalog.shared.search(state.query, windows: model.windows, limit: 4)
            if ws.isEmpty && apps.isEmpty { Text("没有匹配的窗口").font(.system(size: 12)).foregroundStyle(.tertiary) }
            ForEach(Array(ws.enumerated()), id: \.element.id) { i, w in
                HStack(spacing: 2) {
                    Text(i < 9 ? "\(i + 1)" : "").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.purple)
                        .frame(width: 14)
                    WindowRow(model: model, window: w, showApp: true, activate: activate, peek: peek)
                }
            }
            if !apps.isEmpty {
                title(ws.isEmpty ? "📦 App（没有窗口）· ↩ 打开第一个" : "📦 App（没有窗口）", apps.count).padding(.top, 6)
                ForEach(apps) { a in AppRow(app: a, compact: true) { a in close(); AppCatalog.open(a) } }
            }
        }
    }

    var footer: some View {
        HStack(spacing: 8) {
            Button { model.stashFocused() } label: { Label("当前窗口稍后处理", systemImage: "hourglass") }
                .help("当前窗口先退到后台，记在「稍后处理」里；把手上亮一个点提醒你")
            Button {
                close()
                NotificationCenter.default.post(name: .init("WeftOpenArrange"), object: nil)
            } label: { Label("排布建议", systemImage: "sparkles") }
            Spacer()
            Button { close(); NotificationCenter.default.post(name: .init("WeftOpenSettings"), object: nil) } label: { Image(systemName: "gearshape") }
                .help("设置")
        }
        .buttonStyle(.borderless).font(.system(size: 12))
    }
}

/// 侧栏里的缩略图卡片，悬停出现 ◧ ◨
struct MiniCard: View {
    @ObservedObject var model: AppModel
    let window: WindowInfo
    var activate: (WindowInfo) -> Void
    var peek: (WindowInfo?, CGRect) -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.25))
                if let t = model.thumbs[window.id] {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fill).frame(width: 132, height: 82, alignment: .top).clipped()
                } else {
                    Image(nsImage: appIcon(window.pid)).resizable().frame(width: 34, height: 34)
                }
            }
            .frame(width: 132, height: 82)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .bottomLeading) {
                Image(nsImage: appIcon(window.pid)).resizable().frame(width: 18, height: 18).shadow(radius: 2).padding(5)
            }
            .overlay(alignment: .topTrailing) { if hover { PlaceButtons(model: model, window: window).padding(4) } }
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(hover ? Color.accentColor : .white.opacity(0.1), lineWidth: hover ? 2 : 1))
            Text(model.windowName(window)).font(.system(size: 11, weight: .medium)).lineLimit(1)
            if let l = model.labels[window.id] { Text(l).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(width: 132, alignment: .leading)
        .modifier(HoverFrame { h, r in hover = h; peek(h ? window : nil, r) })
        .onTapGesture { activate(window) }
        .contextMenu { WindowMenu(model: model, window: window) }
    }
}

/// 侧栏里的一行窗口
struct WindowRow: View {
    @ObservedObject var model: AppModel
    let window: WindowInfo
    var showApp: Bool
    var activate: (WindowInfo) -> Void
    var peek: (WindowInfo?, CGRect) -> Void
    var drag: ((WindowInfo, Bool) -> Void)? = nil
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: appIcon(window.pid)).resizable().frame(width: showApp ? 22 : 16, height: showApp ? 22 : 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.windowName(window)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                let sub = [model.slotLabel(window.id), model.windowDetail(window).isEmpty ? nil : String(model.windowDetail(window).prefix(36)), model.labels[window.id]].compactMap { $0 }.joined(separator: " · ")
                if !sub.isEmpty { Text(sub).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if hover { PlaceButtons(model: model, window: window) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .modifier(HoverFrame { h, r in hover = h; peek(h ? window : nil, r) })
        .onTapGesture { activate(window) }
        // 拖到屏幕上的某一格：松手就放进去（按住 ⇧ = 叠上去）
        .simultaneousGesture(DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { _ in drag?(window, false) }
            .onEnded { _ in drag?(window, true) })
        .contextMenu { WindowMenu(model: model, window: window) }
    }
}

/// ◧ 放主位（左）· ◨ 放副位（右）
struct PlaceButtons: View {
    @ObservedObject var model: AppModel
    let window: WindowInfo
    var body: some View {
        HStack(spacing: 3) {
            Button { model.place(window, slot: 0) } label: { Image(systemName: "rectangle.lefthalf.filled") }
                .help(model.stageActive ? "放到主位" : "放到左半屏")
            Button { model.place(window, slot: 1) } label: { Image(systemName: "rectangle.righthalf.filled") }
                .help(model.stageActive ? "放到副位（自动分成左右两栏）" : "放到右半屏")
        }
        .buttonStyle(.plain).font(.system(size: 12))
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(Capsule().fill(.ultraThinMaterial))
    }
}

struct WindowMenu: View {
    @ObservedObject var model: AppModel
    let window: WindowInfo
    var body: some View {
        Button("放到\(model.stageActive ? "主位" : "左半屏")") { model.place(window, slot: 0) }
        Button("放到\(model.stageActive ? "副位" : "右半屏")") { model.place(window, slot: 1) }
        SlotMenu(model: model, window: window)
        if model.stageActive && model.stage.companions.contains(window.id) {
            Button("📎 这是附属窗口（浮着）· 放进舞台…") { model.stage.companions.remove(window.id); model.focus(window) }
        }
        if model.stageActive {
            let targets = model.stackTargets(for: window)
            if !targets.isEmpty {
                Menu("🗂 叠到…") {
                    ForEach(targets, id: \.label) { t in Button(t.label) { model.stackWindow(window, display: t.display, slot: t.slot) } }
                }
            }
        }
        if model.stageActive && model.stage.isOnStage(window.id) {
            Button("请下台（退到后台）") { model.dismissFromStage(window.id) }
        }
        Divider()
        Button(model.isPinned(window) ? "取消固定" : "📌 固定") { model.togglePin(window) }
        Button(model.isManuallyStashed(window.id) ? "不用稍后处理了" : "⏳ 稍后处理") { model.toggleStash(window) }
        Button(model.isFloating(window.bundleID) ? "🪶 \(window.appName) 不再随手" : "🪶 \(window.appName) 设成随手窗口") { model.setFloating(window.bundleID, !model.isFloating(window.bundleID)) }
        if !model.contexts.isEmpty {
            Menu("加入事情") {
                ForEach(model.contexts) { c in Button("\(c.emoji) \(c.name)") { model.add(window, to: c) } }
            }
        }
    }
}

/// 悬停时把自己在窗口里的位置报出去（用来摆放旁边的大预览）
struct HoverFrame: ViewModifier {
    let onHover: (Bool, CGRect) -> Void
    func body(content: Content) -> some View {
        content.overlay(GeometryReader { g in
            Color.clear.contentShape(Rectangle()).onHover { onHover($0, g.frame(in: .global)) }
        })
    }
}

/// 侧栏旁边浮出的大预览
struct PeekView: View {
    let window: WindowInfo
    var name: String? = nil
    let thumb: NSImage?
    let label: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.3))
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: appIcon(window.pid)).resizable().frame(width: 64, height: 64)
                }
            }
            .frame(width: 400, height: 250)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 6) {
                Image(nsImage: appIcon(window.pid)).resizable().frame(width: 16, height: 16)
                Text(name ?? (window.title.isEmpty ? window.appName : window.title)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            if let label { Text(label).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
        .padding(10)
    }
}

@MainActor
final class ShelfController {
    let model: AppModel
    let state = ShelfState()
    private var triggers: [NSPanel] = []
    private var panel: KeyPanel?
    private var peekPanel: NSPanel?
    private var pending: DispatchWorkItem?
    private var watch: Timer?
    private var keyMonitor: Any?

    init(model: AppModel) { self.model = model }
    /// 调试：不自动收起
    var stayOpen = false

    var edge: ShelfEdge { model.settings.shelfEdge }

    /// 每条感应条应该在的位置（系统挪屏时会把这些小窗口推走，定时对一下）
    private var triggerFrames: [NSRect] = []
    private var handles: [NSPanel] = []
    private var handleFrames: [NSRect] = []
    static let handleSize = NSSize(width: 18, height: 84)

    func handleRect(_ s: NSScreen) -> NSRect {
        let v = s.visibleFrame, sz = Self.handleSize
        let y = v.maxY - 30 - sz.height - CGFloat(min(max(model.settings.shelfHandleY, 0), 1)) * max(v.height - 60 - sz.height, 0)
        return NSRect(x: edge == .left ? s.frame.minX : s.frame.maxX - sz.width, y: y, width: sz.width, height: sz.height)
    }

    /// 每块屏边上一个小把手：滑上去 / 点一下打开侧栏，上下拖可以挪位置
    private func rebuildHandles() {
        handles.forEach { $0.orderOut(nil) }
        handles.removeAll(); handleFrames.removeAll()
        guard edge != .off, model.settings.shelfHandle else { return }
        for s in NSScreen.screens {
            let rect = handleRect(s)
            let p = NSPanel(contentRect: rect, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let v = HandleView(frame: NSRect(origin: .zero, size: rect.size))
            v.right = edge == .right
            v.onEnter = { [weak self] in if let s = mouseScreen() { self?.scheduleShow(on: s) } }
            v.onExit = { [weak self] in self?.pending?.cancel() }
            v.onClick = { [weak self] in
                guard let self else { return }
                self.pending?.cancel()
                if self.isVisible { self.hide() } else if let s = mouseScreen() { self.show(on: s) }
            }
            v.onDrag = { [weak self, weak p] dy in
                guard let self, let p, let s = p.screen ?? mouseScreen() else { return }
                self.pending?.cancel()
                let vf = s.visibleFrame, sz = Self.handleSize
                var f = p.frame
                f.origin.y = min(max(f.origin.y + dy, vf.minY + 30), vf.maxY - 30 - sz.height)
                p.setFrame(f, display: true)
            }
            v.onDrop = { [weak self, weak p] in
                guard let self, let p, let s = p.screen ?? mouseScreen() else { return }
                let vf = s.visibleFrame, sz = Self.handleSize
                let span = max(vf.height - 60 - sz.height, 1)
                self.model.settings.shelfHandleY = Double((vf.maxY - 30 - sz.height - p.frame.minY) / span)
                self.model.settings.save()
                self.rebuildHandles()
            }
            p.contentView = v
            p.setFrame(rect, display: true)
            p.orderFrontRegardless()
            handles.append(p)
            handleFrames.append(rect)
        }
    }
    private var triggerGuard: Timer?

    /// 每块屏幕边缘放一条 1px 的透明感应条
    func rebuildTriggers() {
        triggers.forEach { $0.orderOut(nil) }
        triggers.removeAll(); triggerFrames.removeAll()
        triggerGuard?.invalidate(); triggerGuard = nil
        rebuildHandles()
        guard edge != .off else { return }
        for s in NSScreen.screens {
            let f = s.frame
            let x = edge == .left ? f.minX : f.maxX - 1
            let rect = NSRect(x: x, y: f.minY + 60, width: 1, height: f.height - 120)
            let p = NSPanel(contentRect: rect, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = NSColor.white.withAlphaComponent(0.001)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let v = EdgeView(frame: p.contentView!.bounds)
            v.autoresizingMask = [.width, .height]
            // 弹在鼠标所在的那块屏（不认建条时的屏：条被系统推到别的屏上时，以前会弹到另一块屏去，看起来就是「不弹了」）
            v.onEnter = { [weak self] in
                guard let self else { return }
                if let s = mouseScreen() { self.scheduleShow(on: s) }
            }
            v.onExit = { [weak self] in self?.pending?.cancel() }
            p.contentView = v
            p.setFrame(rect, display: false)
            p.orderFrontRegardless()
            triggers.append(p)
            triggerFrames.append(rect)
        }
        triggerGuard = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fixTriggers() }
        }
    }

    /// 感应条被推走了就摆回去；屏幕数变了就整套重建
    private func fixTriggers() {
        guard NSScreen.screens.count == triggers.count else { rebuildTriggers(); return }
        for (p, r) in zip(triggers, triggerFrames) where p.frame != r {
            model.stageLog.append(AppModel.clock.string(from: Date()) + " 边缘感应条跑偏了 \(Int(p.frame.minX)),\(Int(p.frame.minY)) → 摆回 \(Int(r.minX)),\(Int(r.minY))")
            p.setFrame(r, display: false)
            p.orderFrontRegardless()
        }
        let waiting = model.stashed.filter(\.isManual).count
        for (p, r) in zip(handles, handleFrames) {
            guard let v = p.contentView as? HandleView else { continue }
            if v.count != waiting { v.count = waiting }
            if p.frame != r && !v.dragging { p.setFrame(r, display: true); p.orderFrontRegardless() }
        }
    }

    private func scheduleShow(on screen: NSScreen) {
        pending?.cancel()
        // 停留一小会儿才弹出，避免鼠标路过误触
        let w = DispatchWorkItem { [weak self] in self?.show(on: screen) }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + model.settings.shelfDelay, execute: w)
    }

    func toggle() { panel == nil ? (mouseScreen().map { show(on: $0) }) : hide() }

    var isVisible: Bool { panel != nil }
    private var resignObserver: Any?

    func show(on screen: NSScreen, byKey: Bool = false) {
        guard panel == nil else { return }
        state.byKey = byKey
        model.refresh(captureThumbs: false)
        model.pinStageDisplay(screen)
        state.query = ""
        let ids = (model.pinnedWindows() + model.predicted(8)).map(\.id) + model.stashed.map(\.windowID)
        model.thumbnails.refresh(ids, maxWidth: 420) { [weak self] new in
            withAnimation(.easeOut(duration: 0.2)) { self?.model.thumbs.merge(new) { $1 } }
        }
        let p = KeyPanel.make(level: .statusBar)
        p.contentView = NSHostingView(rootView: ShelfView(
            model: model, state: state,
            activate: { [weak self] w in self?.hide(); self?.model.focus(w) },
            peek: { [weak self] w, r in self?.state.hovered = w; self?.peek(w, r) },
            close: { [weak self] in self?.hide() },
            drag: { [weak self] w, ended in self?.drag(w, ended: ended) }))
        let vf = screen.visibleFrame
        let width: CGFloat = 312
        let left = edge != .right
        // 离屏幕边缘留一点：笔记本屏的圆角和边框不会挡住侧栏
        let inset: CGFloat = 6
        let target = NSRect(x: left ? screen.frame.minX + inset : screen.frame.maxX - width - inset, y: vf.minY, width: width, height: vf.height)
        p.setFrame(target.offsetBy(dx: left ? -width : width, dy: 0), display: true)
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            p.animator().setFrame(target, display: true)
        }
        panel = p
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return MainActor.assumeIsolated { self.handleKey(e) }
        }
        // 快捷键打开的：在别的 App 里点了一下就收起（不跟着鼠标位置收）
        resignObserver = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { if self?.state.byKey == true { self?.hide() } }
        }
        // 鼠标离开边栏一段距离后自动收起
        watch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel, !self.stayOpen, !self.state.byKey, !self.dragging else { return }
                if !p.frame.insetBy(dx: -24, dy: -24).contains(NSEvent.mouseLocation) { self.hide() }
            }
        }
    }

    private var dragging = false
    /// 从侧栏把一行拖到屏幕上：侧栏变淡让出视线，格子上画落点；松手放进去（落在侧栏上 = 不放）
    private func drag(_ w: WindowInfo, ended: Bool) {
        guard model.stageActive, let p = panel else { return }
        let inside = p.frame.contains(NSEvent.mouseLocation)
        if !ended {
            if !dragging { dragging = true; peek(nil, .zero); p.animator().alphaValue = 0.35 }
            model.shelfDragMoved(w, cancel: inside)
        } else {
            dragging = false
            p.alphaValue = 1
            if model.shelfDragEnded(w, cancel: inside) { hide() }
        }
    }

    /// 侧栏里的按键：数字 = 直达（没在搜时是数字槽位，在搜时是第 n 个结果）；⇧数字 = 把鼠标停着的窗口钉到这个数字
    private func handleKey(_ e: NSEvent) -> NSEvent? {
        if e.keyCode == 53 { // esc
            if !state.query.isEmpty { state.query = "" } else { hide() }
            return nil
        }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty, let n = Self.digit(e.keyCode), n >= 1 else { return e }
        if e.modifierFlags.contains(.shift) {
            let w = state.hovered ?? (state.query.isEmpty ? nil : FuzzyMatcher.rank(model.windows, query: state.query).first)
            if let w { model.pinSlot(n, window: w) } else { Toast.show("把鼠标停在一个窗口上，再按 ⇧\(n) 钉到 \(n) 号", seconds: 1.6) }
            return nil
        }
        if !state.query.isEmpty {
            let ws = FuzzyMatcher.rank(model.windows, query: state.query)
            if ws.indices.contains(n - 1) { let w = ws[n - 1]; hide(); model.focus(w) }
            return nil
        }
        // 没开数字槽位：数字 = 第 n 个常用 App
        if model.settings.slotModifier == .off {
            let apps = model.topApps(6)
            if apps.indices.contains(n - 1) { hide(); model.openTopApp(apps[n - 1]) }
            return nil
        }
        hide()
        if case .empty = model.slotTarget(n), model.slotSuggestions()[n] != nil { model.acceptSlotSuggestion(n) } else { model.jumpSlot(n) }
        return nil
    }

    static func digit(_ code: UInt16) -> Int? {
        let map: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
                                  83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9]
        return map[code]
    }

    func hide() {
        if let o = resignObserver { NSEvent.removeMonitor(o); resignObserver = nil }
        state.byKey = false
        watch?.invalidate(); watch = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        peek(nil, .zero)
        guard let p = panel else { return }
        panel = nil
        model.pinStageDisplay(nil)
        let f = p.frame
        let dx = edge == .right ? f.width : -f.width
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            p.animator().setFrame(f.offsetBy(dx: dx, dy: 0), display: true)
        }) { p.orderOut(nil) }
    }

    /// 悬停预览：浮在侧栏旁边，和悬停的那一行对齐
    private func peek(_ w: WindowInfo?, _ r: CGRect) {
        guard let w, let p = panel else { peekPanel?.orderOut(nil); return }
        if model.thumbs[w.id] == nil {
            model.thumbnails.refresh([w.id], maxWidth: 420) { [weak self] new in
                guard let self else { return }
                self.model.thumbs.merge(new) { $1 }
                if self.peekPanel?.isVisible == true { self.peek(w, r) }
            }
        }
        let pp = peekPanel ?? {
            let n = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            n.level = .statusBar
            n.isOpaque = false
            n.backgroundColor = .clear
            n.ignoresMouseEvents = true
            n.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            peekPanel = n
            return n
        }()
        let host = NSHostingView(rootView: PeekView(window: w, name: model.windowName(w), thumb: model.thumbs[w.id], label: [model.windowDetail(w), model.labels[w.id] ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")))
        pp.contentView = host
        let size = host.fittingSize
        let rowMidY = p.frame.maxY - r.midY
        let x = edge == .right ? p.frame.minX - size.width + 6 : p.frame.maxX - 6
        let screen = p.screen?.visibleFrame ?? p.frame
        let y = min(max(rowMidY - size.height / 2, screen.minY), screen.maxY - size.height)
        pp.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        pp.orderFrontRegardless()
    }
}

final class EdgeView: NSView {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }
}


/// 屏幕边上的小把手：平时一条细细的，鼠标靠近变宽变亮
final class HandleView: NSView {
    var right = false
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}
    var onClick: () -> Void = {}
    var onDrag: (CGFloat) -> Void = { _ in }
    var onDrop: () -> Void = {}
    private(set) var dragging = false
    /// 「稍后处理」里还有几个窗口：把手上亮几个点（最多 3 个）
    var count = 0 { didSet { needsDisplay = true } }
    private var hot = false { didSet { needsDisplay = true } }
    private var downY: CGFloat = 0
    private var moved = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hot = true; onEnter() }
    override func mouseExited(with event: NSEvent) { hot = false; if !dragging { onExit() } }
    override func mouseDown(with event: NSEvent) { downY = NSEvent.mouseLocation.y; moved = false; dragging = true }
    override func mouseDragged(with event: NSEvent) {
        let y = NSEvent.mouseLocation.y
        if !moved && abs(y - downY) < 4 { return }
        moved = true
        onDrag(y - downY)
        downY = y
    }
    override func mouseUp(with event: NSEvent) {
        dragging = false
        if moved { onDrop() } else { onClick() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let w: CGFloat = hot ? 9 : 5
        let h = bounds.height - (hot ? 8 : 20)
        let x = right ? bounds.maxX - w - 3 : 3
        let r = NSRect(x: x, y: (bounds.height - h) / 2, width: w, height: h)
        let path = NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2)
        if hot {
            NSGradient(colors: [NSColor.systemPurple, NSColor.systemBlue])?.draw(in: path, angle: 90)
        } else {
            NSColor.white.withAlphaComponent(0.55).setFill(); path.fill()
        }
        NSColor.black.withAlphaComponent(0.35).setStroke(); path.lineWidth = 1; path.stroke()
        for i in 0..<min(count, 3) {
            let d: CGFloat = 6
            let dot = NSBezierPath(ovalIn: NSRect(x: right ? bounds.maxX - d - 10 : 10, y: r.maxY - d - 2 - CGFloat(i) * (d + 3), width: d, height: d))
            NSColor.systemOrange.setFill(); dot.fill()
            NSColor.black.withAlphaComponent(0.4).setStroke(); dot.lineWidth = 0.5; dot.stroke()
        }
    }
}
