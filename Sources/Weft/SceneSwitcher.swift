import AppKit
import Carbon
import SwiftUI
import WeftCore

// MARK: - 场景切换器
//
// 按快捷键（默认双击右 ⌥），鼠标所在的屏上浮出一排场景卡片：卡片就是场景摆好后的样子（真实窗口截图拼出来）。
// 两指左右滑 / ← → / 滚轮 选，回车或点一下就摆到这块屏上；再按一次快捷键 = 下一个（像 ⌘Tab）。
// 每块屏各自换场景、自由组合；Tab 换目标屏。E 改名，U 用这块屏现在的样子更新这个场景，N 存成新场景，⌫ 删除。

enum SceneItem: Identifiable, Equatable {
    case scene(WorkContext)
    case combo(SceneCombo)
    /// 空桌面：这块屏清空，马上挑窗口放进来
    case blank
    case add

    var id: String {
        switch self {
        case .scene(let c): return c.id
        case .combo(let c): return "combo-" + c.id
        case .blank: return "blank"
        case .add: return "add"
        }
    }
    var objectID: String? {
        switch self { case .scene(let c): return c.id; case .combo(let c): return c.id; case .blank, .add: return nil }
    }
}

@MainActor
final class SceneSwitcherState: ObservableObject {
    @Published var items: [SceneItem] = []
    @Published var index = 0
    /// 摆到哪块屏
    @Published var display = ""
    @Published var renaming = false
    @Published var draft = ""
    @Published var confirmDelete = false
    /// 像切系统桌面那样（⌃← → / 四指滑）调出来的：不抢键盘，松开 ⌃ / 抬手就摆
    @Published var hud = false
    var selected: SceneItem? { items.indices.contains(index) ? items[index] : nil }
}

@MainActor
final class SceneSwitcher {
    let model: AppModel
    let state = SceneSwitcherState()
    /// 打开场景工作台（编辑 / 新建）
    var openStudio: (String?, Bool) -> Void = { _, _ in }
    private var panel: KeyPanel?
    private var keyMon: Any?
    private var scrollMon: Any?
    private var clickMon: Any?
    private var swipe: CGFloat = 0

    init(model: AppModel) { self.model = model }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 快捷键：没开就打开；开着就往后挪一个（连按着选）
    func toggleOrNext() { if isVisible { move(1) } else { show() } }

    func rebuild() {
        let keep = state.selected?.id
        var items: [SceneItem] = []
        // 只列这块屏自己的场景（加上所属的屏没接、临时借住的）：在哪块屏切，就不会切出别的屏的窗口
        let mine = model.switcherScenes(for: state.display).filter { !model.isBlank($0.id) }
        if state.hud {
            // 一个窗口都摆不出来的场景（窗口全关了 / 都在别的桌面上）不进来
            items = mine.filter { c in model.sceneSlots(c).contains { $0.window?.axAvailable == true } }.map { .scene($0) }
            // 最后一张永远是空桌面：⌃→ 走到头就是开一张新的（和调度中心最右边的 ＋ 一个意思）
            items.append(.blank)
        } else {
            if model.profile.displays.count > 1 { items += model.combos.map { .combo($0) } }
            items += mine.filter { !model.sceneDormant($0) }.map { .scene($0) }
            items.append(.blank)
            items.append(.add)
        }
        state.items = items
        if let keep, let i = items.firstIndex(where: { $0.id == keep }) { state.index = i }
        state.index = min(state.index, max(0, items.count - 1))
    }

    func show(display u: String? = nil) {
        guard Permissions.accessibility else { Toast.show("需要先授予辅助功能权限"); return }
        model.refresh(captureThumbs: false)
        let prof = model.profile
        guard let target = u ?? mouseDisplay() ?? prof.main?.uuid, prof.display(uuid: target) != nil else { return }
        model.assignHomes()
        state.display = target
        state.renaming = false
        state.confirmDelete = false
        state.hud = false
        state.index = 0
        rebuild()
        // 默认停在「这块屏现在摆着的场景」的下一个：按一下回车就是换一个
        if let cur = state.items.firstIndex(where: { if case .scene(let c) = $0 { return model.sceneShowing(c) == target }; return false }) {
            state.index = min(cur + 1, state.items.count - 1)
            if case .scene = state.items[state.index] {} else { state.index = cur }
        }
        present(key: true)
    }

    /// 鼠标所在的屏
    func mouseDisplay() -> String? {
        let prof = model.profile
        return mouseScreen().flatMap { s in
            (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).flatMap { n in prof.displays.first { $0.id == n.uint32Value }?.uuid }
        }
    }

    /// 这次浮出来以后挪过没有（⌃ 第一下只浮出来；没挪就松开 ⌃ = 卡片留着，接着用键盘选）
    private var peekMoved = false

    /// ⌃← → / 四指滑：卡片浮出来，选中项往 step 方向走一格（step 0 = 只浮出来，停在这块屏现在的场景上）；已经开着就接着走
    func peek(_ step: Int, display u: String?) {
        if isVisible {
            if step != 0 { move(step); peekMoved = true }
            return
        }
        peekMoved = step != 0
        guard Permissions.accessibility else { return }
        let t0 = Date()
        // 先用手上现成的窗口列表马上浮出来（刷新窗口列表要 ~50ms，手势跟手比数据新 0.1 秒重要），浮出来以后再刷新
        // 很久没刷过（列表可能差很多）就还是先刷一下
        let fresh = !model.windows.isEmpty && Date().timeIntervalSince(model.refreshedAt) < 20
        if !fresh { model.refresh(captureThumbs: false) }
        model.assignHomes()
        defer { model.stageLog.append(AppModel.clock.string(from: Date()) + " 场景卡片浮出 \(Int(Date().timeIntervalSince(t0) * 1000))ms\(fresh ? "" : "（先刷新了窗口列表）")") }
        guard let target = u ?? mouseDisplay() ?? model.profile.main?.uuid, model.profile.display(uuid: target) != nil else { return }
        state.display = target
        state.renaming = false
        state.confirmDelete = false
        state.hud = true
        rebuild()
        let n = state.items.count
        guard n > 0 else {
            state.hud = false
            let r = model.role(of: target).map(DisplayProfile.roleName) ?? "这块屏"
            Toast.show("\(r)还没有场景 · 双击 \(model.settings.sceneTrigger.display) 打开场景切换器新建，或把别的屏的场景换过来（M）", seconds: 2.4)
            return
        }
        state.index = currentIndex(on: target).map { (($0 + step) % n + n) % n } ?? (step >= 0 ? 0 : n - 1)
        present(key: false)
        if fresh { DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.model.refresh(captureThumbs: false)
            self.rebuild()
        } }
    }

    /// 手指刚搭上触控板 / 刚按下 ⌃：卡片可能马上要浮出来，趁这会儿先把窗口列表刷新好
    func prewarm() {
        guard !isVisible, model.stageActive, Date().timeIntervalSince(model.refreshedAt) > 5 else { return }
        model.refresh(captureThumbs: false)
    }

    /// 这块屏现在摆着的场景在第几张
    private func currentIndex(on u: String) -> Int? {
        state.items.firstIndex { if case .scene(let c) = $0 { return model.sceneShowing(c) == u }; return false }
    }

    /// 按着 ⌃ 按 Tab：换到下一块屏，选中项跳到那块屏现在的场景
    func peekNextDisplay() {
        guard isVisible else { return }
        nextDisplay()
    }

    /// 松开 ⌃ / 抬手：摆出选中的场景（就是这块屏现在这个的话，什么都不做）。
    /// ⌃ 只是按了一下、没挪：卡片留着，变成普通的场景切换器（方向键 / Tab / 回车 / Esc，点别处也会关）
    func commitPeek() {
        guard isVisible, state.hud else { return }
        if !peekMoved {
            state.hud = false
            rebuild()
            panel?.makeKeyAndOrderFront(nil)
            return
        }
        if case .scene(let c) = state.selected, model.sceneShowing(c) == state.display { hide(); return }
        apply()
    }

    func cancelPeek() { if isVisible && state.hud { hide() } }

    private func present(key: Bool) {
        // 手势调出来的：只补还没有的缩略图（后台的窗口截图变化不大；一次截几十个窗口会让滑动卡一下）
        let ids = model.sceneWindowIDs
        let want = state.hud ? ids.filter { model.thumbs[$0] == nil } : ids
        model.thumbnails.refresh(want, maxWidth: 520) { [weak self] new in
            guard let self else { return }
            if self.state.hud { self.model.thumbs.merge(new) { $1 } }
            else { withAnimation(.easeOut(duration: 0.25)) { self.model.thumbs.merge(new) { $1 } } }
        }
        let p = panel ?? KeyPanel.make(level: .popUpMenu)
        // 界面只建一次，之后靠 state 驱动（以前每次浮出都重建整排卡片，要 70~150ms）
        if p.contentView is FirstClickHostingView<SceneSwitcherView> { panel = p; place() } else {
        p.contentView = FirstClickHostingView(rootView: SceneSwitcherView(
            model: model, state: state,
            apply: { [weak self] i in self?.apply(i) },
            select: { [weak self] i in self?.state.index = i },
            switchDisplay: { [weak self] in self?.nextDisplay() },
            move: { [weak self] in self?.moveSelected() },
            merge: { [weak self] in self?.merge() },
            edit: { [weak self] in
                guard let self else { return }
                self.hide()
                if case .scene(let c) = self.state.selected { self.openStudio(c.id, false) } else { self.openStudio(nil, false) }
            }))
        panel = p
        place()
        }
        p.alphaValue = 0
        // 键盘接着留在你正在用的窗口里（⌃ 还按着，方向键由事件截取送过来）
        if key { p.makeKeyAndOrderFront(nil) } else { p.orderFrontRegardless() }
        NSAnimationContext.runAnimationGroup { $0.duration = key ? 0.18 : 0.12; p.animator().alphaValue = 1 }
        installMonitors()
    }

    private func place() {
        guard let p = panel, let d = model.profile.display(uuid: state.display) else { return }
        let primaryH = NSScreen.screens.first?.frame.height ?? d.frame.height
        let ns = NSRect(x: d.frame.minX, y: primaryH - d.frame.maxY, width: d.frame.width, height: d.frame.height)
        let w = min(ns.width - 60, 1240), h: CGFloat = 420
        p.setFrame(NSRect(x: ns.midX - w / 2, y: ns.midY - h / 2, width: w, height: h), display: true)
    }

    func hide() {
        for m in [keyMon, scrollMon, clickMon].compactMap({ $0 }) { NSEvent.removeMonitor(m) }
        keyMon = nil; scrollMon = nil; clickMon = nil
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.14; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
    }

    private func installMonitors() {
        if keyMon == nil {
            keyMon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, self.isVisible else { return e }
                return MainActor.assumeIsolated { self.handleKey(e) }
            }
        }
        if scrollMon == nil {
            // 两指左右滑（触控板）/ 滚轮：一格一格地挪
            scrollMon = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, self.isVisible else { return e }
                MainActor.assumeIsolated { self.scroll(e) }
                return nil
            }
        }
        if clickMon == nil {
            clickMon = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }

    private func scroll(_ e: NSEvent) {
        if e.phase == .began || e.phase == .mayBegin { swipe = 0 }
        let dx = e.hasPreciseScrollingDeltas ? -e.scrollingDeltaX : 0
        let dy = e.hasPreciseScrollingDeltas ? 0 : -(e.scrollingDeltaY != 0 ? e.scrollingDeltaY : e.scrollingDeltaX) * 12
        swipe += abs(dx) > abs(dy) ? dx : dy
        let step: CGFloat = 55
        while swipe >= step { swipe -= step; move(1) }
        while swipe <= -step { swipe += step; move(-1) }
        if e.phase == .ended || e.phase == .cancelled { swipe = 0 }
    }

    func move(_ d: Int) {
        guard !state.items.isEmpty, !state.renaming else { return }
        state.confirmDelete = false
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            state.index = (state.index + d + state.items.count) % state.items.count
        }
    }

    /// 换目标屏：卡片换成那块屏自己的场景，选中它现在摆着的那个
    private func nextDisplay() {
        let ds = model.profile.displays
        guard ds.count > 1, let i = ds.firstIndex(where: { $0.uuid == state.display }) else { return }
        state.display = ds[(i + 1) % ds.count].uuid
        state.confirmDelete = false
        rebuild()
        state.index = currentIndex(on: state.display) ?? state.items.firstIndex { if case .scene = $0 { return true }; return false } ?? 0
        place()
    }

    /// 把选中的场景换到下一块屏（M）
    func moveSelected() {
        guard case .scene(let c) = state.selected else { return }
        let roles = model.profile.roleMap.keys.sorted { DisplayProfile.roleOrder($0) < DisplayProfile.roleOrder($1) }
        guard roles.count > 1 else { Toast.show("只接了一块屏"); return }
        let cur = c.home ?? model.role(of: state.display) ?? roles[0]
        let next = roles[((roles.firstIndex(of: cur) ?? -1) + 1) % roles.count]
        model.moveScene(c.id, to: next)
        rebuild()
    }

    func apply(_ i: Int? = nil) {
        let i = i ?? state.index
        guard state.items.indices.contains(i) else { return }
        let u = state.display
        switch state.items[i] {
        case .scene(let c):
            hide()
            model.switchScene(c, on: u)
        case .combo(let c):
            hide()
            model.applyCombo(c)
        case .blank:
            hide()
            model.newDesk(on: u)
        case .add:
            hide()
            openStudio(nil, true)
        }
    }

    private func merge() {
        hide()
        let a = NSAlert()
        a.messageText = "把每块屏的系统桌面合并成 1 个？"
        a.informativeText = "有 \(model.scenesElsewhere) 个场景里的窗口在别的系统桌面上，Weft 够不着，所以摆不出来。\n合并后，那些桌面上的窗口会被系统挪到当前桌面（不会关掉任何窗口），以后用 Weft 场景代替系统桌面来回切换。"
        a.addButton(withTitle: "合并")
        a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { model.mergeDesktops() }
    }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        let code = Int(e.keyCode)
        if state.renaming {
            switch code {
            case kVK_Escape: state.renaming = false; return nil
            case kVK_Return:
                if let id = state.selected?.objectID { model.renameScene(id, state.draft) }
                state.renaming = false
                rebuild()
                return nil
            default: return e   // 交给输入框
            }
        }
        switch code {
        case kVK_Escape: hide(); return nil
        case kVK_LeftArrow, kVK_UpArrow: move(-1); return nil
        case kVK_RightArrow, kVK_DownArrow: move(1); return nil
        case kVK_Tab: nextDisplay(); return nil
        case kVK_Return, kVK_Space: apply(); return nil
        case kVK_Delete, kVK_ForwardDelete:
            guard let id = state.selected?.objectID else { return nil }
            if state.confirmDelete {
                model.deleteSceneOrCombo(id)
                state.confirmDelete = false
                rebuild()
            } else { state.confirmDelete = true }
            return nil
        default: break
        }
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if let n = Int(ch), n >= 1, n <= min(9, state.items.count) { apply(n - 1); return nil }
        switch ch {
        case "e":
            hide()
            if case .scene(let c) = state.selected { openStudio(c.id, false) } else { openStudio(nil, false) }
        case "u":
            if case .scene(let c) = state.selected { model.updateScene(c, from: state.display); rebuild() }
        case "n":
            if model.saveScene(from: state.display) != nil { rebuild(); state.index = max(0, state.items.count - 2) }
        case "d":
            let u = state.display
            hide()
            model.newDesk(on: u)
        case "c":
            model.saveComboFromScreens(); rebuild()
        case "m":
            moveSelected()
        default: break
        }
        return nil
    }
}

// MARK: - 界面

struct SceneSwitcherView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: SceneSwitcherState
    var apply: (Int) -> Void
    var select: (Int) -> Void
    var switchDisplay: () -> Void
    var move: () -> Void
    var merge: () -> Void
    var edit: () -> Void

    static let cardW: CGFloat = 280
    static let spacing: CGFloat = 22

    var body: some View {
        let target = model.profile.display(uuid: state.display)
        let aspect = target.map { $0.visible.width / max($0.visible.height, 1) } ?? 1.6
        VStack(spacing: 12) {
            header
            GeometryReader { g in
                let step = Self.cardW + Self.spacing
                let offset = g.size.width / 2 - Self.cardW / 2 - CGFloat(state.index) * step
                HStack(alignment: .center, spacing: Self.spacing) {
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { i, item in
                        let dist = abs(i - state.index)
                        SceneCardView(model: model, state: state, item: item, number: i + 1, aspect: aspect, selected: i == state.index)
                            .frame(width: Self.cardW)
                            .scaleEffect(i == state.index ? 1.0 : 0.84)
                            .opacity(dist == 0 ? 1 : dist == 1 ? 0.7 : 0.4)
                            .onTapGesture { if i == state.index { apply(i) } else { withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { select(i) } } }
                    }
                }
                .offset(x: offset)
                .frame(width: g.size.width, height: g.size.height, alignment: .leading)
            }
            .frame(height: Self.cardW / aspect + 74)
            .clipped()
            footer
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 26).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .padding(10)
    }

    var header: some View {
        HStack(spacing: 10) {
            Text("🎬 场景").font(.system(size: 16, weight: .heavy, design: .rounded))
            if model.profile.displays.count > 1 {
                HStack(spacing: 4) {
                    Text("这块屏的场景").font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(model.profile.displays.sorted { DisplayProfile.roleOrder(model.role(of: $0.uuid) ?? "") < DisplayProfile.roleOrder(model.role(of: $1.uuid) ?? "") }, id: \.uuid) { d in
                        let on = d.uuid == state.display
                        Text(model.role(of: d.uuid).map(DisplayProfile.roleName) ?? d.name)
                            .help(d.name)
                            .font(.system(size: 11, weight: on ? .bold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(on ? Color.purple.opacity(0.45) : Color.white.opacity(0.08)))
                            .onTapGesture { if !on { switchDisplay() } }
                    }
                    Text(state.hud ? "⌃Tab 换屏" : "Tab 换屏").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if model.scenesElsewhere > 0 {
                Button { merge() } label: {
                    Label("\(model.scenesElsewhere) 个窗口在别的系统桌面上，摆不出来 · 合并桌面…", systemImage: "rectangle.on.rectangle.slash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder var footer: some View {
        HStack(spacing: 8) {
            if let sel = state.selected {
                switch sel {
                case .scene(let c):
                    let slots = model.sceneSlots(c).filter { !$0.member.bundleID.isEmpty }
                    let away = slots.filter(\.elsewhere).count
                    let gone = slots.filter { $0.window == nil }.count
                    Text("\(c.plan?.first?.layout.title ?? "") · \(slots.count - gone) 个窗口" + (away > 0 ? " · \(away) 个在别的桌面" : "") + (gone > 0 ? " · \(gone) 个没开（不占格子）" : ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                case .combo(let c):
                    Text("组合 · \(c.parts.count) 块屏一起摆，回到各自上次的屏").font(.system(size: 11)).foregroundStyle(.secondary)
                case .blank:
                    Text("这块屏清空（现在的场景原样留着），马上挑一个窗口放进来 · 什么都没放就切走，它自己消失").font(.system(size: 11)).foregroundStyle(.secondary)
                case .add:
                    Text("在场景工作台里拖窗口进格子，建一个新场景").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if state.confirmDelete { Text("再按一次 ⌫ 删除").font(.system(size: 11, weight: .bold)).foregroundStyle(.red) }
            Spacer()
            if state.hud || model.profile.displays.count < 2 { Text(state.hud ? "按着 ⌃ 再按 ← → 选（最右边是空桌面）· ⌃Tab 换屏 · 松开 ⌃ 就摆出来 · Esc 不换" : "← → / 两指滑 选 · ↩ 摆出来 · 数字直达 · D 空桌面 · Tab 换屏").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1) }
            if !state.hud, model.profile.displays.count > 1, case .scene = state.selected {
                Button { move() } label: { Label("换到另一块屏", systemImage: "arrow.left.arrow.right").font(.system(size: 11, weight: .medium)).fixedSize() }
                    .buttonStyle(.bordered).controlSize(.small).help("这个场景以后归另一块屏（M）")
            }
            if !state.hud, case .scene(let c) = state.selected {
                ForEach(model.otherRoles(than: c), id: \.self) { r in
                    let partner = model.linkedPartner(of: c.id, role: r)
                    Menu {
                        Button("不跟（解绑）") { model.bind(c.id, role: r, to: nil) }.disabled(partner == nil)
                        Divider()
                        ForEach(model.bindCandidates(for: c, role: r)) { o in
                            Button((o.id == partner?.id ? "✓ " : "") + "\(o.emoji) \(o.name)") { model.bind(c.id, role: r, to: o.id) }
                        }
                    } label: {
                        Label(partner.map { "\(DisplayProfile.roleName(r))跟着切：\($0.emoji) \($0.name)" } ?? "绑\(DisplayProfile.roleName(r))一起切…", systemImage: "link")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .menuStyle(.borderedButton).controlSize(.small).fixedSize()
                    .help("绑上以后，切到这个场景时\(DisplayProfile.roleName(r))也换成选的那个场景；反过来也一样")
                }
            }
            Button { edit() } label: { Label("编辑场景", systemImage: "square.and.pencil").font(.system(size: 11, weight: .medium)) }
                .buttonStyle(.bordered).controlSize(.small).help("打开场景工作台（E）")
        }
    }
}

struct SceneCardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: SceneSwitcherState
    let item: SceneItem
    let number: Int
    let aspect: CGFloat
    let selected: Bool

    var body: some View {
        let h = SceneSwitcherView.cardW / aspect
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                preview(h)
                    .frame(width: SceneSwitcherView.cardW, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.purple : .white.opacity(0.12), lineWidth: selected ? 3 : 1))
                    .shadow(color: selected ? .purple.opacity(0.45) : .clear, radius: 14)
                if case .scene(let c) = item, model.homeAway(c), let h = c.home {
                    Text("\(DisplayProfile.roleName(h)) 的 · 没接")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.85)))
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if case .scene(let c) = item, let u = model.sceneShowing(c) {
                    let here = u == state.display
                    Text(here ? "正在这块屏" : "在另一块屏")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(here ? Color.green.opacity(0.85) : Color.gray.opacity(0.8)))
                        .padding(7)
                }
            }
            HStack(spacing: 6) {
                if number <= 9 {
                    Text("\(number)").font(.system(size: 10, weight: .heavy, design: .rounded))
                        .frame(width: 17, height: 17)
                        .background(Circle().fill(selected ? Color.purple : Color.white.opacity(0.15)))
                }
                if selected && state.renaming {
                    TextField("名字（开头可以放个 emoji）", text: $state.draft)
                        .textFieldStyle(.roundedBorder).font(.system(size: 13))
                } else {
                    Text(title).font(.system(size: 13, weight: selected ? .bold : .medium)).lineLimit(1)
                }
            }
        }
    }

    var title: String {
        switch item {
        case .scene(let c): return "\(c.emoji) \(c.name)" + (model.linkGroup(of: c.id) != nil ? " 🔗" : "")
        case .combo(let c): return "\(c.emoji) \(c.name)"
        case .blank: return "🫙 空桌面"
        case .add: return "＋ 新场景"
        }
    }

    @ViewBuilder func preview(_ h: CGFloat) -> some View {
        switch item {
        case .scene(let c):
            ScenePreview(model: model, scene: c, size: CGSize(width: SceneSwitcherView.cardW, height: h))
        case .combo(let combo):
            // 每块屏一个小屏幕，并排
            let pairs = SceneBook.assign(combo, to: model.profile)
            HStack(spacing: 6) {
                ForEach(Array(combo.parts.enumerated()), id: \.offset) { _, part in
                    if let c = model.contexts.first(where: { $0.id == part.sceneID }) {
                        let u = pairs.first { $0.sceneID == part.sceneID }?.display
                        let d = u.flatMap { model.profile.display(uuid: $0) }
                        let a = d.map { $0.visible.width / max($0.visible.height, 1) } ?? 1.6
                        let w = (SceneSwitcherView.cardW - 18) / CGFloat(max(combo.parts.count, 1))
                        VStack(spacing: 3) {
                            ScenePreview(model: model, scene: c, size: CGSize(width: w, height: min(h - 26, w / a)))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Text(d.map { $0.isBuiltin ? "笔记本" : String($0.name.prefix(8)) } ?? "（屏不在）")
                                .font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(width: SceneSwitcherView.cardW, height: h)
            .background(Color.black.opacity(0.35))
        case .blank:
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [Color.purple.opacity(0.22), Color.blue.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(spacing: 6) {
                    Image(systemName: "macwindow.badge.plus").font(.system(size: 26, weight: .light))
                    Text("空桌面\n清空这块屏，拉一个窗口过来").font(.system(size: 11)).multilineTextAlignment(.center)
                }.foregroundStyle(.white.opacity(0.85))
            }
        case .add:
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.04))
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                VStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 26, weight: .light))
                    Text("新建场景\n（打开场景工作台）").font(.system(size: 11)).multilineTextAlignment(.center)
                }.foregroundStyle(.secondary)
            }
        }
    }
}

/// 场景缩略图：按场景的版式，把每个格子里的窗口截图拼上去
struct ScenePreview: View {
    @ObservedObject var model: AppModel
    let scene: WorkContext
    let size: CGSize

    var body: some View {
        let spec = scene.plan?.first?.spec ?? StageSpec(.focus)
        // 已经关掉的窗口不画（摆出来时也不占格子）
        let slots = model.liveSlots(scene)
        let n = max(1, min(slots.count, spec.layout.slots))
        let eff = StageGeometry.effective(spec, filled: n)
        let k: CGFloat = 10
        let frames = StageGeometry.frames(eff, in: CGRect(x: 0, y: 0, width: size.width * k, height: size.height * k), gap: 40)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.12), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
            ForEach(Array(frames.enumerated()), id: \.offset) { i, f in
                let s = i < slots.count ? slots[i] : nil
                cell(s, CGSize(width: f.width / k, height: f.height / k))
                    .frame(width: f.width / k, height: f.height / k)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .offset(x: f.minX / k, y: f.minY / k)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder func cell(_ s: AppModel.SceneSlot?, _ sz: CGSize) -> some View {
        ZStack {
            Color.white.opacity(0.07)
            if let w = s?.window, let t = model.thumbs[w.id] {
                Image(nsImage: t).resizable().aspectRatio(contentMode: .fill).frame(width: sz.width, height: sz.height, alignment: .top).clipped()
                    .opacity(s?.elsewhere == true ? 0.35 : 1)
            }
            if let w = s?.window {
                Image(nsImage: appIcon(w.pid)).resizable().frame(width: min(26, sz.height * 0.4), height: min(26, sz.height * 0.4))
                    .shadow(radius: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.thumbs[w.id] == nil ? .center : .bottomLeading)
                    .padding(4)
            } else if let m = s?.member {
                // 窗口关了：灰的 App 图标
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: m.bundleID)
                Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
                    .resizable().frame(width: 22, height: 22).opacity(0.3).saturation(0)
            }
            if s?.elsewhere == true {
                Text("别处").font(.system(size: 8, weight: .bold)).foregroundStyle(.orange)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(3)
            }
        }
    }
}
