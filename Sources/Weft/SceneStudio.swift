import AppKit
import SwiftUI
import WeftCore

// MARK: - 场景工作台
//
// 建场景、改场景的地方：左边是你的场景，中间是选中场景的样子（版式 + 每一格放谁），右边是所有窗口。
// 从右边把窗口拖进中间的格子就行；点一格也能从列表里挑。场景正摆在某块屏上时，这里改了屏幕立刻跟着变。
// 没有任何场景时，Weft 一启动就打开这里。

@MainActor
final class StudioState: ObservableObject {
    @Published var selected: String?
    @Published var search = ""
    @Published var previewDisplay: String?
    /// 正在给第几格挑窗口（工作台里盖一层挑选面板）
    @Published var pickSlot: Int?
}

@MainActor
final class SceneStudio {
    let model: AppModel
    let state = StudioState()
    private var window: NSWindow?

    init(model: AppModel) { self.model = model }

    func show(select id: String? = nil, new: Bool = false) {
        model.refresh(captureThumbs: false)
        if new { state.selected = model.createScene() }
        else if let id { state.selected = id }
        if state.selected == nil || !model.scenes.contains(where: { $0.id == state.selected }) { state.selected = model.scenes.first?.id }
        if state.previewDisplay.flatMap({ model.profile.display(uuid: $0) }) == nil {
            state.previewDisplay = model.stage.currentDisplay() ?? model.profile.main?.uuid
        }
        model.thumbnails.refresh(model.windows.map(\.id), maxWidth: 360) { [weak self] new in
            withAnimation(.easeOut(duration: 0.2)) { self?.model.thumbs.merge(new) { $1 } }
        }
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.title = "Weft 场景"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: StudioView(model: model, state: state))
            w.setContentSize(NSSize(width: 1180, height: 760))
            w.minSize = NSSize(width: 980, height: 620)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct StudioView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: StudioState

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Divider()
            editor.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            library.frame(width: 290)
        }
        .padding(.top, 28)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { picker }
        .onChange(of: state.selected) { _, _ in state.pickSlot = nil }
    }

    /// 点一格 → 盖一层挑选面板（就在工作台窗口里，输入框点得动、能直接打字）
    @ViewBuilder var picker: some View {
        if let i = state.pickSlot, let c = current {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { state.pickSlot = nil }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("放进「\(c.emoji) \(c.name)」的第 \(i + 1) 格").font(.system(size: 14, weight: .bold))
                        Spacer()
                        Button { state.pickSlot = nil } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 16)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction)
                    }
                    WindowPickList(model: model) { w in
                        state.pickSlot = nil
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.setSceneSlot(c.id, i, w) }
                    }
                }
                .padding(14)
                .frame(width: 420, height: 520)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.purple.opacity(0.5), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            }
            .transition(.opacity)
        }
    }

    var current: WorkContext? { model.contexts.first { $0.id == state.selected } }

    /// 场景按所属的屏分组：笔记本、扩展屏1…，没归屏的放最后
    var groups: [(title: String, scenes: [WorkContext])] {
        let present = Set(model.profile.roleMap.keys)
        let roles = Set(model.scenes.compactMap(\.home)).union(present).sorted { DisplayProfile.roleOrder($0) < DisplayProfile.roleOrder($1) }
        var out: [(String, [WorkContext])] = roles.compactMap { r in
            let list = model.scenes.filter { $0.home == r }
            guard !list.isEmpty || present.contains(r) else { return nil }
            let d = model.profile.display(forRole: r)
            return ("\(DisplayProfile.roleName(r))\(d.map { $0.isBuiltin ? "" : " · \($0.name.prefix(12))" } ?? " · 没接")", list)
        }
        let loose = model.scenes.filter { $0.home == nil }
        if !loose.isEmpty { out.append(("还没归屏", loose)) }
        return out
    }

    // MARK: 左：场景列表

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("场景").font(.system(size: 18, weight: .heavy, design: .rounded)).padding(.horizontal, 14)
            Text("场景就是你的桌面：每个场景归一块屏，在哪块屏切就只换那块屏的场景（\(model.settings.sceneTrigger.display) / ⌃← →）").font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(groups, id: \.title) { g in
                    if groups.count > 1 {
                        Text(g.title).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6).padding(.horizontal, 4)
                    }
                    ForEach(g.scenes) { c in
                        let sel = c.id == state.selected
                        let on = model.sceneShowing(c)
                        HStack(spacing: 8) {
                            Text(c.emoji).font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name).font(.system(size: 12, weight: sel ? .bold : .medium)).lineLimit(1)
                                let n = c.plan?.first?.members.filter { !$0.bundleID.isEmpty }.count ?? 0
                                Text("\(c.plan?.first?.layout.title ?? "") · \(n) 个窗口" + (model.sceneDormant(c) ? " · 都没开（切换器里先不列）" : "")).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if model.linkGroup(of: c.id) != nil { Text("🔗").font(.system(size: 10)).help("绑着别的屏：切到它时一起切") }
                            if let on {
                                Text(model.profile.display(uuid: on).map { $0.isBuiltin ? "笔记本" : String($0.name.prefix(6)) } ?? "")
                                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 2).background(Capsule().fill(Color.green.opacity(0.8)))
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(sel ? Color.accentColor.opacity(0.25) : Color.clear))
                        .contentShape(Rectangle())
                        .onTapGesture { state.selected = c.id }
                    }
                    }
                    Group {
                        Text("🪶 随手窗口（不进场景、切场景不藏）").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10).padding(.horizontal, 4)
                        if model.settings.floatingApps.isEmpty {
                            Text("还没有。右边窗口卡片上右键「设成随手」，或者新窗口弹出「放进哪一块」时点「🪶 以后随手」").font(.system(size: 10)).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10)
                        }
                        ForEach(model.settings.floatingApps, id: \.self) { b in
                            HStack(spacing: 6) {
                                Text("🪶")
                                Text(model.appName(bundleID: b)).font(.system(size: 11)).lineLimit(1)
                                Spacer(minLength: 0)
                                Button { model.setFloating(b, false) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).help("不再随手：又能放进场景")
                            }
                            .font(.system(size: 10)).padding(.horizontal, 10).padding(.vertical, 4)
                        }
                    }
                    if !model.combos.isEmpty {
                        Text("组合（打开联动 = 一起切）").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10).padding(.horizontal, 4)
                        ForEach(model.combos) { combo in
                            HStack(spacing: 6) {
                                Text(combo.emoji)
                                Text(combo.name).font(.system(size: 11)).lineLimit(1)
                                Spacer(minLength: 0)
                                Toggle("联动", isOn: Binding(get: { combo.isLinked }, set: { model.setLinked(combo.id, $0) }))
                                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                                    .help("打开后：切到组合里任何一个场景，别的屏跟着切")
                                Button { model.applyCombo(combo) } label: { Image(systemName: "play.fill") }.buttonStyle(.plain).help("摆出来")
                                Button { model.deleteSceneOrCombo(combo.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).help("删除组合")
                            }
                            .font(.system(size: 10)).padding(.horizontal, 10).padding(.vertical, 4)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            VStack(spacing: 6) {
                Button { state.selected = model.createScene(on: state.previewDisplay) } label: { Label("新场景", systemImage: "plus").frame(maxWidth: .infinity) }
                    .controlSize(.large)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.organizing ? "AI 正在看你的窗口…" : "AI 帮我建一批").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.leading, 2).padding(.top, 4)
                    AIAskBox(model: model, placeholder: "想怎么分？可以不写")
                        .help("比如：Claude 有时单独、有时配微信；浏览器几个窗口分开放。AI 会照你的意思来，再看窗口大小和屏幕放不放得下")
                }
                if let p = model.proposal, !p.isEmpty {
                    if let sm = model.deskSummary { Text(sm).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    ForEach(p, id: \.name) { prop in
                        HStack(spacing: 4) {
                            Text("\(prop.emoji) \(prop.name)").font(.system(size: 11, weight: .medium)).lineLimit(1)
                            if prop.scenes.count > 1 { Text("🔗").font(.system(size: 9)).help("跨两块屏：拆成两个场景，绑在一起切") }
                            Spacer(minLength: 0)
                            Button { model.tryProposal(prop) } label: { Image(systemName: "eye") }.buttonStyle(.plain).help("先摆出来看看")
                            Button { model.dropProposal(prop.name) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).help("这个不要")
                        }
                        .help(prop.reason)
                    }
                    FloatingSuggestion(model: model)
                    Button { model.acceptProposal(); state.selected = model.scenes.first?.id } label: {
                        Text("加入 AI 建议的 \(p.count) 个场景").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent)
                }
                if let m = model.aiMessage { Text(m).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(12)
        }
    }

    // MARK: 中：编辑

    @ViewBuilder var editor: some View {
        if let c = current, let pl = c.plan?.first {
            VStack(alignment: .leading, spacing: 16) {
                NameRow(model: model, scene: c)
                HStack(spacing: 6) {
                    ForEach(StageLayout.allCases, id: \.self) { l in
                        let sel = pl.layout == l
                        Button { model.setSceneLayout(c.id, l) } label: {
                            VStack(spacing: 4) {
                                LayoutIcon(spec: sel ? pl.spec : StageSpec(l), selected: sel, size: CGSize(width: 36, height: 24))
                                Text(l.title).font(.system(size: 10, weight: sel ? .bold : .regular))
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(sel ? Color.purple.opacity(0.25) : Color.white.opacity(0.04)))
                        }.buttonStyle(.plain)
                    }
                    if !pl.spec.ratioChoices.isEmpty {
                        Button { model.cycleSceneRatio(c.id) } label: { Label(pl.spec.ratioLabel, systemImage: "rectangle.split.2x1") }
                            .controlSize(.small).help("换比例")
                    }
                    Spacer()
                    if model.profile.displays.count > 1 || c.home.map({ model.profile.display(forRole: $0) == nil }) == true {
                        let roles = Set(model.profile.roleMap.keys).union([c.home].compactMap { $0 }).sorted { DisplayProfile.roleOrder($0) < DisplayProfile.roleOrder($1) }
                        Picker("属于", selection: Binding(get: { c.home ?? "" }, set: { r in
                            model.moveScene(c.id, to: r)
                            if let u = model.profile.display(forRole: r)?.uuid { state.previewDisplay = u }
                        })) {
                            if c.home == nil { Text("还没归屏").tag("") }
                            ForEach(roles, id: \.self) { r in
                                let d = model.profile.display(forRole: r)
                                Text(DisplayProfile.roleName(r) + (d.map { $0.isBuiltin ? "" : " · \($0.name.prefix(12))" } ?? "（没接）")).tag(r)
                            }
                        }.frame(width: 220).controlSize(.small).help("这个场景只出现在这块屏的切换器里")
                    }
                }
                BindRow(model: model, scene: c)
                GeometryReader { g in
                    let d = model.homeDisplay(c).flatMap { model.profile.display(uuid: $0) } ?? state.previewDisplay.flatMap { model.profile.display(uuid: $0) } ?? model.profile.main
                    let aspect = d.map { $0.visible.width / max($0.visible.height, 1) } ?? 1.6
                    let w = min(g.size.width, g.size.height * aspect), h = w / aspect
                    SceneCanvas(model: model, scene: c, size: CGSize(width: w, height: h), onPick: { state.pickSlot = $0 })
                        .frame(width: g.size.width, height: g.size.height)
                }
                HStack(spacing: 8) {
                    if let on = model.sceneShowing(c) {
                        Label("正摆在\(model.profile.display(uuid: on).map { $0.isBuiltin ? "笔记本" : $0.name } ?? "")上 · 这里改了屏幕立刻跟着变", systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 11)).foregroundStyle(.green)
                    } else {
                        Text("从右边把窗口拖进格子；点一格也能挑").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // 摆到它自己的屏；所属的屏没接时可以临时摆到别的屏（不改归属，插回来自动回去）
                    if let u = model.homeDisplay(c) {
                        Button { model.switchScene(c, on: u) } label: {
                            Label("摆到\(model.role(of: u).map(DisplayProfile.roleName) ?? "")", systemImage: model.role(of: u) == DisplayProfile.laptopRole ? "laptopcomputer" : "display")
                        }
                        .buttonStyle(.borderedProminent).tint(.purple)
                    } else {
                        ForEach(model.profile.displays, id: \.uuid) { d in
                            Button { model.switchScene(c, on: d.uuid) } label: {
                                Label("\(c.home == nil ? "" : "临时")摆到\(model.role(of: d.uuid).map(DisplayProfile.roleName) ?? d.name)", systemImage: d.isBuiltin ? "laptopcomputer" : "display")
                            }
                            .buttonStyle(.borderedProminent).tint(.purple)
                        }
                    }
                }
            }
            .padding(22)
        } else {
            VStack(spacing: 14) {
                Text("🎬").font(.system(size: 48))
                Text("先建几个场景").font(.system(size: 20, weight: .bold))
                Text("场景 = 一块屏上要一起看的几个窗口。比如「回消息」：微信 + 企业微信；「写代码」：编辑器 + 终端 + 网页。\n建好以后按 \(model.settings.sceneTrigger.display) 左右滑着切，每块屏各自换。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                HStack {
                    Button("新建一个") { state.selected = model.createScene(on: state.previewDisplay) }.controlSize(.large)
                    Button("让 AI 帮我建一批") { model.organize() }.controlSize(.large).buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: 右：窗口库

    var library: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("窗口").font(.system(size: 14, weight: .bold))
            Text("拖进中间的格子").font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("搜索（支持拼音）", text: $state.search).textFieldStyle(.roundedBorder)
            ScrollView {
                let inScene = Set(current.map { model.sceneSlots($0).compactMap { $0.window?.id } } ?? [])
                let list = state.search.isEmpty ? model.mruOrder() : FuzzyMatcher.rank(model.windows, query: state.search)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    ForEach(list) { w in
                        LibraryCard(model: model, window: w, used: inScene.contains(w.id))
                            .draggable(String(w.id))
                            .contextMenu {
                                if model.isFloating(w.bundleID) {
                                    Button("不再随手：\(w.appName) 又能放进场景") { model.setFloating(w.bundleID, false) }
                                } else {
                                    Button("🪶 把 \(w.appName) 设成随手窗口") { model.setFloating(w.bundleID, true) }
                                }
                            }
                    }
                }
            }
        }
        .padding(14)
    }
}

struct NameRow: View {
    @ObservedObject var model: AppModel
    let scene: WorkContext
    @State private var name = ""
    @State private var emoji = ""
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 10) {
            TextField("", text: $emoji).font(.system(size: 26)).frame(width: 46).multilineTextAlignment(.center)
                .textFieldStyle(.plain).onSubmit(save)
            TextField("场景名字", text: $name).font(.system(size: 22, weight: .bold)).textFieldStyle(.plain).onSubmit(save)
            Spacer()
            Button(role: .destructive) {
                if confirmDelete { model.deleteSceneOrCombo(scene.id) } else { confirmDelete = true }
            } label: { Label(confirmDelete ? "再点一次删除" : "删除", systemImage: "trash") }
                .controlSize(.small)
        }
        .onAppear { load() }
        .onChange(of: scene.id) { load() }
        .onChange(of: name) { save() }
        .onChange(of: emoji) { save() }
    }

    func load() { name = scene.name; emoji = scene.emoji; confirmDelete = false }
    func save() { model.setSceneName(scene.id, name: name, emoji: emoji) }
}

/// 场景的样子：每一格都能接住拖过来的窗口，点一下从列表挑
struct SceneCanvas: View {
    @ObservedObject var model: AppModel
    let scene: WorkContext
    let size: CGSize
    var onPick: (Int) -> Void = { _ in }

    var body: some View {
        let spec = scene.plan?.first?.spec ?? StageSpec(.focus)
        let slots = model.sceneSlots(scene)
        let k: CGFloat = 10
        let frames = StageGeometry.frames(spec, in: CGRect(x: 0, y: 0, width: size.width * k, height: size.height * k), gap: 90)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
            ForEach(Array(frames.enumerated()), id: \.offset) { i, f in
                SlotCell(model: model, sceneID: scene.id, index: i, slot: i < slots.count ? slots[i] : nil,
                         size: CGSize(width: f.width / k, height: f.height / k), onPick: { onPick(i) })
                    .offset(x: f.minX / k, y: f.minY / k)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
    }
}

struct SlotCell: View {
    @ObservedObject var model: AppModel
    let sceneID: String
    let index: Int
    let slot: AppModel.SceneSlot?
    let size: CGSize
    var onPick: () -> Void = {}
    @State private var targeted = false
    @State private var hover = false

    var body: some View {
        let w = slot?.window
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(targeted ? Color.purple.opacity(0.4) : Color.white.opacity(0.06))
            if let w, let t = model.thumbs[w.id] {
                Image(nsImage: t).resizable().aspectRatio(contentMode: .fill).frame(width: size.width, height: size.height, alignment: .top).clipped()
                    .opacity(targeted ? 0.3 : (slot?.elsewhere == true ? 0.4 : 0.9))
            }
            VStack(spacing: 6) {
                if let w {
                    Image(nsImage: appIcon(w.pid)).resizable().frame(width: 34, height: 34).shadow(radius: 4)
                    Text(w.title.isEmpty ? w.appName : w.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.black.opacity(0.55)))
                    if slot?.elsewhere == true {
                        Text("在别的系统桌面上").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                    }
                } else if let m = slot?.member, !m.bundleID.isEmpty {
                    Text("「\(m.title.isEmpty ? m.bundleID : m.title)」已关闭").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "plus.rectangle.on.rectangle").font(.system(size: 22, weight: .light))
                    Text("拖一个窗口进来，或点这里挑").font(.system(size: 11))
                }
            }
            .foregroundStyle(.white).padding(8)
            Text(index == 0 ? "主" : "\(index + 1)").font(.system(size: 10, weight: .heavy, design: .rounded))
                .frame(width: 20, height: 20).background(Circle().fill(index == 0 ? Color.purple : Color.white.opacity(0.2)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(8)
            if hover && (w != nil || slot?.member.bundleID.isEmpty == false) {
                Button { model.setSceneSlot(sceneID, index, nil) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 18)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(8)
                    .help("这一格空出来")
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(targeted ? Color.purple : .white.opacity(hover ? 0.35 : 0.15),
                                                                  style: StrokeStyle(lineWidth: targeted ? 3 : 1, dash: w == nil ? [6, 4] : [])))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { onPick() }
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let id = UInt32(s), let w = model.window(id) else { return false }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.setSceneSlot(sceneID, index, w) }
            return true
        } isTargeted: { targeted = $0 }
    }
}

struct WindowPickList: View {
    @ObservedObject var model: AppModel
    var pick: (WindowInfo) -> Void
    @State private var q = ""
    @FocusState private var searching: Bool
    var list: [WindowInfo] { Array((q.isEmpty ? model.mruOrder() : FuzzyMatcher.rank(model.windows, query: q)).prefix(40)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("搜索窗口（支持拼音）", text: $q).textFieldStyle(.roundedBorder)
                .focused($searching)
                .onAppear { DispatchQueue.main.async { searching = true } }
                .onSubmit { if let w = list.first { pick(w) } }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(list) { w in
                        Button { pick(w) } label: {
                            HStack(spacing: 8) {
                                Image(nsImage: appIcon(w.pid)).resizable().frame(width: 18, height: 18)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(w.title.isEmpty ? w.appName : w.title).font(.system(size: 12)).lineLimit(1)
                                    Text(w.appName + (w.axAvailable ? "" : " · 在别的系统桌面")).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LibraryCard: View {
    @ObservedObject var model: AppModel
    let window: WindowInfo
    let used: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25))
                if let t = model.thumbs[window.id] {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fill).frame(height: 72, alignment: .top).clipped()
                } else {
                    Image(nsImage: appIcon(window.pid)).resizable().frame(width: 28, height: 28)
                }
            }
            .frame(height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                Image(nsImage: appIcon(window.pid)).resizable().frame(width: 16, height: 16).shadow(radius: 2).padding(4)
            }
            .overlay(alignment: .topTrailing) {
                if used { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).padding(4) }
                else if !window.axAvailable { Text("别处").font(.system(size: 8, weight: .bold)).foregroundStyle(.orange).padding(4) }
            }
            .opacity(window.axAvailable ? 1 : 0.6)
            Text(window.title.isEmpty ? window.appName : window.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
    }
}


/// 「切到它时，扩展屏1 跟着切到 [不跟 ▾]」
private struct BindRow: View {
    @ObservedObject var model: AppModel
    let scene: WorkContext
    var body: some View {
        let roles = model.otherRoles(than: scene)
        if !roles.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "link").foregroundStyle(.purple)
                Text("跨屏绑定 · 切到它时").font(.system(size: 11, weight: .semibold))
                ForEach(roles, id: \.self) { r in
                    let cands = model.bindCandidates(for: scene, role: r)
                    Picker(DisplayProfile.roleName(r) + " 跟着切到", selection: Binding(
                        get: { model.linkedPartner(of: scene.id, role: r)?.id ?? "" },
                        set: { model.bind(scene.id, role: r, to: $0.isEmpty ? nil : $0) })) {
                        Text("不跟").tag("")
                        ForEach(cands) { o in Text("\(o.emoji) \(o.name)").tag(o.id) }
                    }
                    .frame(maxWidth: 300).controlSize(.small).disabled(cands.isEmpty)
                    .help(cands.isEmpty ? "\(DisplayProfile.roleName(r)) 上还没有场景" : "绑定后在任何一块屏上切到其中一个，另一个也跟着摆出来；选「不跟」就解绑")
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.1)))
        }
    }
}

