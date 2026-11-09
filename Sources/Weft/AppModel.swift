import AppKit
import SwiftUI
import WeftAI
import WeftCore

/// 全局状态：窗口、缩略图、事情、固定、停靠、舞台、习惯预测、AI
@MainActor
final class AppModel: ObservableObject {
    let system = SystemWindows()
    let store = Store.shared
    lazy var engine = LayoutEngine(actions: system)
    let habits = HabitTracker()
    lazy var stash = StashManager(actions: system)
    lazy var stage = StageManager(actions: system, stash: stash)
    let slots = SlotStore()
    let memory = MemoryStore()
    /// 记忆变了（笔记、提示）时刷新界面
    @Published var memoryRevision = 0
    @Published var digesting = false
    /// 槽位变化时刷新界面
    @Published var slotRevision = 0
    /// 用槽位跳过去之前在用的窗口：再按一次同一个号码就跳回来
    private var slotFrom: UInt32?
    /// 按了一次空号码（看到推荐），3 秒内再按一次就钉上
    private var emptySlotPress: (Int, Date)?
    let thumbnails = ThumbnailService()

    @Published var windows: [WindowInfo] = []
    @Published var thumbs: [UInt32: NSImage] = [:]
    @Published var predictions: [UInt32: Double] = [:]
    @Published var contexts: [WorkContext] = []
    /// 场景组合（几块屏同时摆）
    @Published var combos: [SceneCombo] = []
    /// 每块屏现在摆着哪个场景（屏幕 → 场景 id）。这块屏上的调整会自动存进这个场景
    @Published var showingScene: [String: String] = [:]
    /// 每个位置（笔记本 / 扩展屏1…）上次摆的属于它自己的场景：屏插回来 / 换了显示器时照这个摆回去
    var roleShowing: [String: String] = [:]
    /// 上次看到的「位置 → 显示器」
    var lastRoleMap: [String: String]?
    /// 每个位置上次是哪台显示器（换了一台时提示一下）
    var knownDisplays: [String: String] = [:]
    var sceneUsedAt: [String: Date] = [:]
    /// 切到一个不在任何场景里的窗口：它单独开了新场景，界面问你要不要放进刚才那个场景的某一块
    var onOfferPlacement: (PlacementOffer) -> Void = { _ in }
    @Published var pinned: [WorkContext.Member] = []
    @Published var stashed: [StashEntry] = []
    @Published var proposal: [ContextProposal]?
    @Published var organizing = false
    /// AI 整理时你写给它的要求（可以空着）
    @Published var organizeRequest = ""
    /// AI 建议设成随手窗口的 App（bundleID）
    @Published var proposedFloating: [String] = []
    @Published var floatingReason = ""
    @Published var aiMessage: String?
    @Published var profile = DisplayProfile(displays: [])
    /// 同一个 App 有多个窗口时的区分说明
    @Published var labels: [UInt32: String] = [:]

    // 舞台
    @Published var stageActive = false
    @Published var stageRevision = 0

    // AI 排布
    @Published var arranging = false
    @Published var arrangeOptions: [ArrangementOption]?
    @Published var arrangeMessage: String?
    @Published var arrangeVisible = false

    @Published var settings = WeftSettings.load()
    @Published var aiConfig = AIConfig.load()
    @Published var models: [ModelEntry] = []

    /// 设置变了（快捷键、侧边栏位置），由 AppDelegate 重新绑定
    var onSettingsChanged: () -> Void = {}
    var onStageChanged: (Bool) -> Void = { _ in }

    private let me = ProcessInfo.processInfo.processIdentifier
    private var trackTimer: Timer?
    private var stageTimer: Timer?
    private var lastStageFocus: UInt32?
    private var tick = 0

    static let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .mint, .red, .yellow]
    func color(_ i: Int) -> Color { Self.palette[((i % Self.palette.count) + Self.palette.count) % Self.palette.count] }

    init() {
        let db = store.load(ContextDB.self, "contexts.json") ?? ContextDB()
        // 以前「一个场景跨两块屏」：拆成每块屏一个场景 + 一个组合（场景不绑屏幕，可以自由组合）
        let split = SceneBook.split(db.contexts)
        contexts = split.contexts
        combos = (db.combos ?? []) + split.combos
        pinned = db.pinned
        if !split.combos.isEmpty { DispatchQueue.main.async { [weak self] in self?.saveContexts() } }
    }

    func start() {
        engine.exclude = { [weak self] in Set(self?.stash.entries.map(\.windowID) ?? []) }
        engine.log = { msg in
            NSLog("[Weft] %@", msg)
            if msg.contains("自动恢复") || msg.contains("降级") {
                DispatchQueue.main.async { Toast.show("🖥 " + msg + " · 打开总控后 ⌘Z 可撤销") }
            }
        }
        stage.log = { [weak self] msg in
            NSLog("[Weft] %@", msg)
            // 最近 300 条舞台事件，`Weft ctl dump` 里能看到，排查「怎么又乱了」用
            let t = Self.clock.string(from: Date())
            DispatchQueue.main.async { self?.stageLog.append("\(t) \(msg)"); if (self?.stageLog.count ?? 0) > 300 { self?.stageLog.removeFirst(50) } }
        }
        applyStageSettings()
        // 上次异常退出时还停靠在屏幕外的窗口，先放回来
        if Permissions.accessibility { stash.restoreAll() }
        stashed = stash.entries
        trackTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackTick() }
        }
        refreshModels()
    }

    private func trackTick() {
        guard Permissions.accessibility else { return }
        habits.observe(focused: system.focusedWindow())
        tick += 1
        if tick % 20 == 0 && !stageActive { engine.autosaveTick() }
        if tick % 60 == 0 { habits.persistIfNeeded() }
        if stageActive { comboTick() }
        // 每天让 AI 复盘一次（配了 AI、开着记忆、攒够了数据）
        if tick % 600 == 30 { autoDigest() }
        // 舞台留下的后台记录（锁屏 / 别的桌面上当时放不回去的）：窗口能操作了就放回原位
        if tick % 5 == 0 && !stageActive && stash.entries.contains(where: { $0.byStage == true }) && system.canObserve {
            let live = system.windows()
            for e in stash.entries where e.byStage == true {
                if live.first(where: { $0.id == e.windowID })?.axAvailable == true { stash.unstash(e.windowID, focus: false) }
            }
            stashed = stash.entries
        }
    }

    func shutdown() {
        habits.persistIfNeeded()
        stash.restoreAll()
    }

    // MARK: 设置

    /// App 的显示名（钉钉、访达），没在运行就用 App 文件名
    func appName(bundleID b: String) -> String {
        if let n = NSRunningApplication.runningApplications(withBundleIdentifier: b).first?.localizedName { return n }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) { return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
        return b.split(separator: ".").last.map(String.init) ?? b
    }

    func saveSettings() {
        settings.save()
        applyStageSettings()
        onSettingsChanged()
    }

    private func applyStageSettings() {
        stage.gap = CGFloat(settings.stageGap)
        stage.autoPromote = settings.stageAutoPromote
        stage.floatingApps = Set(settings.floatingApps)
    }

    // MARK: 刷新

    /// 上次刷新窗口列表的时间（场景卡片浮出时，刚刷过就不再同步刷，先浮出来）
    private(set) var refreshedAt = Date.distantPast

    func refresh(captureThumbs: Bool = true, only ids: [UInt32]? = nil) {
        refreshedAt = Date()
        profile = system.profile()
        if lastRoleMap == nil, !profile.roleMap.isEmpty { lastRoleMap = profile.roleMap; for (r, u) in profile.roleMap { knownDisplays[r] = u } }
        if contexts.contains(where: { $0.home == nil }) { assignHomes() }
        windows = system.windows().filter { $0.pid != me }
        stash.prune(live: windows)
        stashed = stash.entries
        predictions = habits.predict(windows)
        labels = WindowLabeler.labels(windows.map(displayable), profile: profile)
        thumbnails.prune(keep: Set(windows.map(\.id)))
        thumbs = thumbnails.cache
        if captureThumbs {
            // 后台窗口在屏幕外也能截到
            let target = ids ?? windows.filter { !$0.isMinimized }.map(\.id)
            thumbnails.refresh(target) { [weak self] new in
                guard let self else { return }
                withAnimation(.easeOut(duration: 0.2)) { self.thumbs.merge(new) { $1 } }
            }
        }
    }

    /// 停靠 / 后台的窗口按原来的位置来描述
    func displayable(_ w: WindowInfo) -> WindowInfo {
        guard let e = stash.entry(w.id) else { return w }
        var c = w
        c.frame = e.originalFrame
        c.displayUUID = profile.display(containing: e.originalFrame.center)?.uuid
        return c
    }

    func window(_ id: UInt32) -> WindowInfo? { windows.first { $0.id == id } }

    /// 「接下来可能用」：习惯预测 top N
    func predicted(_ n: Int = 5) -> [WindowInfo] {
        windows.filter { (predictions[$0.id] ?? 0) > 0.05 }
            .sorted { (predictions[$0.id] ?? 0) > (predictions[$1.id] ?? 0) }
            .prefix(n).map { $0 }
    }

    /// ⌥Tab 的顺序：真实使用顺序优先，其次 z 序
    func mruOrder() -> [WindowInfo] {
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [WindowInfo] = habits.mru.compactMap { byID[$0] }
        let seen = Set(out.map(\.id))
        out += windows.filter { !seen.contains($0.id) }.sorted { $0.zIndex < $1.zIndex }
        // 当前窗口放第一位，这样默认选中的第二个就是「上一个」
        if let cur = system.focusedWindowID(), let i = out.firstIndex(where: { $0.id == cur }), i != 0 {
            out.insert(out.remove(at: i), at: 0)
        }
        return out
    }

    func resolved(_ c: WorkContext) -> [WindowInfo] { ContextResolver.resolve(c.members, in: windows) }
    func context(of w: WindowInfo) -> WorkContext? { contexts.first { resolved($0).contains { $0.id == w.id } } }
    func isPinned(_ w: WindowInfo) -> Bool { ContextResolver.resolve(pinned, in: windows).contains { $0.id == w.id } }
    func pinnedWindows() -> [WindowInfo] { ContextResolver.resolve(pinned, in: windows) }
    func isManuallyStashed(_ id: UInt32) -> Bool { stash.entry(id)?.isManual ?? false }
    var currentWindow: WindowInfo? { (habits.currentWindowID ?? system.focusedWindowID()).flatMap { window($0) } }

    /// 习惯搭配：当前窗口 + 最常和它来回切的窗口
    func habitPair() -> (WindowInfo, WindowInfo)? {
        guard let cur = currentWindow,
              let other = Arranger.habitPair(focused: cur, windows: windows, coUsage: habits.coUsage(windows)) else { return nil }
        return (cur, other)
    }

    // MARK: 动作

    /// 去某个窗口。舞台模式下 = 请它上台。
    func focus(_ w: WindowInfo) {
        if stageActive {
            // 附属窗口（台上 App 弹出来的看图 / 预览）：就是浮着的，点它 = 切过去
            if stage.companions.contains(w.id) { system.focus(w.id); return }
            if !stage.isOnStage(w.id), handleActivation(w) { return }
            stage.present(w)
            stageChanged()
            return
        }
        if stash.isStashed(w.id) { stash.unstash(w.id); stashed = stash.entries; return }
        system.focus(w.id)
    }

    // MARK: 数字槽位

    var slotKey: String { settings.slotModifier.symbol }

    func slotLabel(_ id: UInt32) -> String? {
        guard settings.slotModifier != .off, let n = slots.slot(of: id) else { return nil }
        return "\(slotKey)\(n)"
    }

    /// ⌥n：跳到 n 号窗口；它已经在最前面时，跳回刚才那个
    func jumpSlot(_ n: Int) {
        guard Permissions.accessibility else { Toast.show("需要先授予辅助功能权限"); return }
        // 快速路径：钉住的窗口还在、句柄有缓存 → 不枚举全部窗口，直接过去（约 5ms，完整枚举要 100ms+）
        if let b = slots.bindings[n] {
            let current = system.focusedWindowID()
            let onStageOrOff = !stageActive || stage.isOnStage(b.windowID)
            if b.windowID == current {
                if let back = slotFrom, back != b.windowID, (!stageActive || stage.isOnStage(back)), system.quickFocus(back) {
                    slotFrom = b.windowID; slotRevision += 1; return
                }
            } else if onStageOrOff, !stash.isStashed(b.windowID), system.quickFocus(b.windowID) {
                // 记下「从哪来」：只认真实窗口（有的 App 报告的焦点窗口是隐藏小窗），取不到就用最近用过的
                slotFrom = current.flatMap { system.isCached($0) && window($0) != nil ? $0 : nil }
                    ?? habits.mru.first { $0 != b.windowID && system.isCached($0) }
                Toast.show("\(n) · \(b.appName)\(b.title.isEmpty || b.title == b.appName ? "" : " · " + String(b.title.prefix(24)))", seconds: 0.8)
                slotRevision += 1
                return
            }
        }
        let live = system.windows().filter { $0.pid != me }
        let current = system.focusedWindowID()
        switch slots.resolve(n, windows: live) {
        case .window(let w):
            if w.id == current, !(stageActive && stash.isStashed(w.id)) {
                // 回到刚才那个；记录丢了（或是隐藏窗口）就用最近用过的另一个窗口
                let liveIDs = Set(live.map(\.id))
                let back = [slotFrom].compactMap { $0 }.filter { liveIDs.contains($0) && $0 != w.id }.first
                    ?? habits.mru.first { liveIDs.contains($0) && $0 != w.id }
                if let back, let bw = live.first(where: { $0.id == back }) {
                    slotFrom = w.id
                    focus(bw)
                } else {
                    Toast.show("\(slotKey)\(n) 就是当前窗口", seconds: 0.9)
                }
                return
            }
            slotFrom = current.flatMap { c in live.contains { $0.id == c } ? c : nil } ?? habits.mru.first { id in live.contains { $0.id == id } }
            focus(w)
            Toast.show("\(n) · \(w.appName)\(w.title.isEmpty || w.title == w.appName ? "" : " · " + String(w.title.prefix(24)))", seconds: 0.8)
        case .app(let bid, let name):
            slotFrom = current
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                Toast.show("\(n) · 打开 \(name)", seconds: 1.2)
            } else {
                Toast.show("\(slotKey)\(n) 绑定的「\(name)」找不到了")
            }
        case .empty:
            if let w = slotSuggestions()[n] {
                if let (m, t) = emptySlotPress, m == n, Date().timeIntervalSince(t) < 3 {
                    emptySlotPress = nil
                    pinSlot(n, window: w)
                    focus(w)
                } else {
                    emptySlotPress = (n, Date())
                    Toast.show("\(slotKey)\(n) 还空着 · 推荐「\(short(w))」（你最常用的之一）· 再按一次 \(slotKey)\(n) 钉上并打开", seconds: 3)
                }
            } else {
                Toast.show("\(slotKey)\(n) 还是空的 · 按 \(slotKey)⇧\(n) 把当前窗口钉上来", seconds: 2.2)
            }
        }
        slotRevision += 1
    }

    /// ⌥⇧n：把窗口（默认是当前窗口）钉到 n 号
    func pinSlot(_ n: Int, window: WindowInfo? = nil) {
        guard let w = window ?? system.focusedWindow() ?? currentWindow else { Toast.show("没有可以钉住的窗口"); return }
        let old = slots.assign(n, displayable(w))
        let name = w.title.isEmpty || w.title == w.appName ? w.appName : "\(w.appName) · \(w.title.prefix(20))"
        Toast.show("📌 \(name) → \(slotKey)\(n)" + (old.map { "（替换了 \($0.appName)）" } ?? ""), seconds: 1.8)
        slotRevision += 1
    }

    func clearSlot(_ n: Int) { slots.clear(n); slotRevision += 1 }

    /// 槽位条用：n 号现在对应什么
    func slotTarget(_ n: Int) -> SlotTarget { slots.resolve(n, windows: windows) }

    /// 放到指定位置：舞台模式下是槽位（0 主位 / 1 副位），否则是左右半屏
    func place(_ w: WindowInfo, slot: Int) {
        if stageActive {
            let u = stage.currentDisplay()
            if slot >= 1, (stage.stage(for: u)?.spec.layout.slots ?? 1) < 2 { stage.setSpec(StageSpec(.split), display: u); stage.defaultSpec = StageSpec(.split) }
            stage.present(w, on: u, slot: slot)
            stageChanged()
            syncScenes()
        } else {
            snap(w, slot == 0 ? .leftHalf : .rightHalf)
        }
    }

    func toggleStash(_ w: WindowInfo) {
        if stageActive && stage.isOnStage(w.id) { stage.dismiss(w.id); stageChanged() }
        if isManuallyStashed(w.id) { stash.unstash(w.id) } else { stash.stash(displayable(w), original: stash.entry(w.id)?.originalFrame) }
        stashed = stash.entries
    }

    func stashFocused() {
        guard let id = habits.currentWindowID ?? system.focusedWindowID() else { return }
        if window(id) == nil { refresh(captureThumbs: false) }
        guard let w = window(id) else { return }
        thumbnails.refresh([id]) { [weak self] new in self?.thumbs.merge(new) { $1 } }
        if stageActive && stage.isOnStage(id) { stage.dismiss(id); stageChanged() }
        stash.stash(w)
        stashed = stash.entries
        Toast.show("🅿️ 已停靠：\(w.title.isEmpty ? w.appName : w.title)")
    }

    func togglePin(_ w: WindowInfo) {
        if let i = pinned.firstIndex(where: { ContextResolver.resolve([$0], in: [w]).count == 1 }) {
            pinned.remove(at: i)
        } else {
            pinned.append(ContextResolver.member(w))
        }
        saveContexts()
    }

    func snap(_ w: WindowInfo, _ region: Region) {
        guard let d = profile.display(uuid: displayable(w).displayUUID) ?? profile.main else { return }
        engine.undo.push("分屏", windows: windows)
        if stash.isStashed(w.id) { stash.release(w.id); stashed = stash.entries }
        system.setMinimized(w.id, false)
        system.setFrame(w.id, region.rel.absolute(in: d.visible))
        system.focus(w.id)
    }

    func undo() {
        if let l = engine.undoLast() { Toast.show("↩︎ 已撤销：\(l)") } else { Toast.show("没有可撤销的操作") }
    }

    /// 把一对窗口并排（习惯搭配）
    func pairUp(_ a: WindowInfo, _ b: WindowInfo) {
        if stageActive {
            let u = stage.currentDisplay() ?? profile.main?.uuid ?? ""
            stage.apply(scene: [(u, StageSpec(.split, ratio: 0.6), [a.id, b.id])])
            stageChanged()
        } else {
            arrangeNow([(profile.display(uuid: displayable(a).displayUUID) ?? profile.main, StageSpec(.split, ratio: 0.6), [a.id, b.id])])
        }
        Toast.show("🤝 并排：\(short(a)) ｜ \(short(b))")
    }

    func short(_ w: WindowInfo) -> String {
        let t = w.title.isEmpty ? w.appName : w.title
        return t.count > 14 ? String(t.prefix(14)) + "…" : t
    }

    /// 不进舞台，直接按版式摆好这些窗口（其余窗口不动）
    func arrangeNow(_ scenes: [(DisplayInfo?, StageSpec, [UInt32])]) {
        refresh(captureThumbs: false)
        engine.undo.push("AI 排布", windows: windows)
        var front: [UInt32] = []
        for (d, spec, ids) in scenes {
            guard let d else { continue }
            let frames = StageGeometry.frames(StageGeometry.effective(spec, filled: ids.count), in: d.visible, gap: CGFloat(settings.stageGap))
            for (i, id) in ids.enumerated() where i < frames.count {
                if stash.isStashed(id) { stash.release(id) }
                system.setMinimized(id, false)
                system.setFrame(id, frames[i])
                front.append(id)
            }
        }
        stashed = stash.entries
        for id in front.reversed() { system.focus(id) }
    }

    // MARK: 舞台

    func toggleStage() { stageActive ? exitStage() : enterStage() }

    var stageLog: [String] = []
    static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    /// 撤销上一步舞台操作（换了谁、换了版式、拖了位置……）
    func undoStage() {
        guard stageActive else { return }
        if stage.undo() { stageChanged(); refocusStage(); syncScenes(); Toast.show("↶ 回到上一步", seconds: 1.0) } else { Toast.show("没有可以撤销的了", seconds: 1.0) }
    }

    /// 一键归位：乱了就按它
    func healStage() {
        guard stageActive else { return }
        stage.heal()
        stageChanged()
        Toast.show("✨ 归位：窗口回到各自的格子", seconds: 1.2)
    }

    func enterStage() {
        guard Permissions.accessibility else { Toast.show("需要先授予辅助功能权限"); return }
        guard !stageActive else { return }
        stage.enter(focused: system.focusedWindowID())
        beginStage()
        Toast.show("🎭 舞台模式 · 切到哪个窗口它就上台 · 再按 \(settings.stageTrigger.display) 退出", seconds: 3.5)
    }

    func beginStage() {
        stageActive = true
        lastStageFocus = nil
        if !profile.roleMap.isEmpty { lastRoleMap = profile.roleMap; for (r, u) in profile.roleMap { knownDisplays[r] = u } }
        assignHomes()
        stageTimer?.invalidate()
        var n = 0
        // 焦点变化靠通知即时响应（⌘Tab、点 Dock）；定时器只做兜底和每 2 秒一次的对账
        // 焦点一变（关了窗口、切了 App）就顺手对一次账：关窗后格子能马上补位，平时的对账就可以放慢
        system.onFocusChange = { [weak self] in MainActor.assumeIsolated { self?.checkStageFocus(); self?.reconcileSoon = true } }
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                guard let model = self else { return }
                // App 激活后它的焦点窗口要过一小会儿才稳定
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak model] in
                    MainActor.assumeIsolated { if model?.missionControlPause() == false { model?.checkStageFocus(); model?.reconcileSoon = true } }
                }
            }
        }
        stageTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.missionControlPause() else { return }
                n += 1
                // 鼠标按着、刚松开 2 秒内：每 0.35 秒看一次（拖窗口归位要跟手）；平时放慢：
                // 焦点变化有系统通知即时处理，这里约 1 秒兜底一次；App 自己跑偏约 1.4 秒内归位
                let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
                if down { self.lastMouseDown = Date() }
                let busy = down || Date().timeIntervalSince(self.lastMouseDown) < 2
                // 拖窗口过屏：画落点预览，松手插进去（要在磁吸之前处理，不然会被当成「拖进别的格子换位」）
                if down && !self.wasDown { self.dragBegan() }
                if down { self.dragMoved() }
                if !down && self.wasDown { self.dragEnded() }
                self.wasDown = down
                if busy || n % 3 == 0 { self.checkStageFocus() }
                if (busy || n % 4 == 0) && self.stage.settle() { self.stageChanged(); self.syncScenes() }
                // 全量对账要逐个问所有窗口，比较贵：有动静时约 2 秒一次，空闲时约 4 秒一次，焦点变化后立刻补一次
                if self.reconcileSoon || n % (busy ? 6 : 12) == 0 {
                    self.reconcileSoon = false
                    // 对账：真有窗口进出格子 / 藏起放回才通知界面（以前每 2 秒无条件刷新一遍，开着工作台时空闲也占 20% CPU）
                    let before = (self.stage.stages, self.stash.entries)
                    self.stage.reconcile(mru: self.habits.mru)
                    if self.stage.stages != before.0 || self.stash.entries != before.1 { self.stageChanged() }
                }
            }
        }
        stage.onRelayout = { [weak self] _ in self?.stageChanged() }
        stage.activationHandler = { [weak self] w in self?.handleActivation(w) ?? false }
        stage.isSceneMember = { [weak self] w in self?.bestScene(containing: w) != nil }
        stageChanged()
        onStageChanged(true)
    }

    /// 调度中心（四指上滑）开着时舞台暂停：那时窗口服务器报的是调度中心里缩略图的位置，
    /// 以前 Weft 以为后台窗口被拉回了屏幕，当场又把它们一个个藏回右下角（还把有的窗口改小了）。关掉后再等一会儿，等位置报回正常
    private var mcQuietUntil = Date.distantPast
    func missionControlPause() -> Bool {
        if MissionControl.isShowing {
            if mcQuietUntil < Date() { stageLog.append(Self.clock.string(from: Date()) + " 调度中心开着：舞台暂停") }
            mcQuietUntil = Date().addingTimeInterval(1.2)
            return true
        }
        return Date() < mcQuietUntil
    }

    private var activationObserver: NSObjectProtocol?
    private var lastMouseDown = Date.distantPast
    private var wasDown = false

    // MARK: 拖进来插入
    //
    // 从另一块屏（或浮着的窗口）拖到某块屏上：那块屏的版式长一格把它插进去，拖动中显示落点。
    // 同一块屏里拖还是换位，随手 App 不管。

    var onDropPreview: (CGRect?, String) -> Void = { _, _ in }
    private var dragWin: WindowInfo?
    private var dragFrom: (frame: CGRect, display: String?)?
    private var dragPlan: StageManager.InsertPlan?

    private func dragBegan() {
        dragPlan = nil
        guard let w = system.focusedWindow(), !settings.floatingApps.contains(w.bundleID) else { dragWin = nil; return }
        dragWin = w
        dragFrom = (w.frame, profile.display(containing: w.frame.center)?.uuid)
        // 拖动期间预览要跟手：单独开一个快的计时器，松手就停（平时不花这份 CPU）
        dragTimer?.invalidate()
        let t = Timer(timeInterval: 0.06, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.dragWin != nil, CGEventSource.buttonState(.combinedSessionState, button: .left) else { t.invalidate(); return }
                self.dragMoved()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        dragTimer = t
    }
    private var dragTimer: Timer?

    private func dragMoved() {
        guard let w = dragWin, let from = dragFrom, let f = system.frames(of: [w.id])[w.id] else { return }
        let moved = abs(f.minX - from.frame.minX) + abs(f.minY - from.frame.minY) > 30 && abs(f.width - from.frame.width) < 4
        let p = CGEvent(source: nil)?.location ?? f.center
        let u = profile.display(containing: p)?.uuid
        guard moved, let u, u != from.display, let plan = stage.planInsert(w.id, display: u, at: p) else {
            if dragPlan != nil { dragPlan = nil; onDropPreview(nil, "") }
            return
        }
        if plan != dragPlan {
            dragPlan = plan
            let n = plan.slots.compactMap { $0 }.count
            let label = plan.replaces != nil ? "换掉这一格" : (n > (stage.stage(for: u)?.windows.count ?? 0) ? "插到这里 · \(plan.spec.layout.title)" : "放这里")
            onDropPreview(plan.frame, label)
        }
    }

    private func dragEnded() {
        defer { dragWin = nil; dragFrom = nil; dragPlan = nil; dragTimer?.invalidate(); dragTimer = nil }
        guard let w = dragWin, dragPlan != nil else { return }
        onDropPreview(nil, "")
        // 按松手那一刻的位置重新算一次
        let p = CGEvent(source: nil)?.location ?? .zero
        guard let u = profile.display(containing: p)?.uuid, let plan = stage.planInsert(w.id, display: u, at: p) else { return }
        if stage.insert(w, plan: plan) { stageChanged(); syncScenes() }
    }
    private var reconcileSoon = false
    private var lastStuckCheck = Date.distantPast

    private func checkStageFocus() {
        guard stageActive, let id = system.focusedWindow()?.id else { return }
        // 键盘焦点停在后台（屏幕外）的窗口上 = 一定不对（你打的字进了看不见的窗口）：即使是同一个窗口，也每秒重新判断一次
        let stuck = id == lastStageFocus && stash.isStashed(id) && !stage.isOnStage(id) && Date().timeIntervalSince(lastStuckCheck) > 1
        guard id != lastStageFocus || stuck else { return }
        if stuck { lastStuckCheck = Date() }
        lastStageFocus = id
        switch stage.focusChanged(id) {
        case .promoted: stageChanged()
        case .later: lastStageFocus = nil   // Weft 刚摆完窗口，等一下再判断，别把这次切换丢了
        case .onStage, .ignored: break
        }
    }

    func exitStage() {
        guard stageActive else { return }
        guard stage.exit() else { Toast.show("屏幕锁着，解锁后再退出舞台"); return }
        stageTimer?.invalidate(); stageTimer = nil
        system.onFocusChange = {}
        if let o = activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); activationObserver = nil }
        stageActive = false
        showingScene.removeAll()
        stashed = stash.entries
        stageChanged()
        onStageChanged(false)
        Toast.show("已退出舞台模式，其余窗口已回到原位")
    }

    func stageChanged() {
        if stashed != stash.entries { stashed = stash.entries }
        stageRevision += 1
        onStageRevision()
    }
    var onStageRevision: () -> Void = {}

    /// 当前屏幕的舞台（面板打开在哪块屏，就是哪块）
    var currentStage: DisplayStage? { stage.stage(for: stage.currentDisplay()) }

    /// 面板打开 / 关闭时调用：舞台控制条操作面板所在的那块屏幕
    func pinStageDisplay(_ screen: NSScreen?) {
        guard let screen, let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            stage.pinnedDisplay = nil; return
        }
        stage.pinnedDisplay = profile.displays.first { $0.id == n.uint32Value }?.uuid
        stageRevision += 1
    }

    func selectStageDisplay(_ uuid: String) { stage.pinnedDisplay = uuid; stageRevision += 1 }

    /// 舞台控制条可以切换的屏幕（多屏时显示）
    var stageDisplays: [(uuid: String, name: String)] {
        profile.displays.map { ($0.uuid, $0.isBuiltin ? "笔记本" : String($0.name.prefix(10))) }
    }

    /// 换版式：已有的窗口留在前面的格子，空出来的格子由界面弹候选让你挑
    func setStageLayout(_ layout: StageLayout, display: String? = nil) {
        guard stageActive else { return }
        let u = display ?? stage.currentDisplay()
        var spec = stage.stage(for: u)?.spec ?? StageSpec(layout)
        if spec.layout != layout { spec = StageSpec(layout, mirrored: spec.mirrored) }
        stage.setSpec(spec, display: u)
        stage.defaultSpec = StageSpec(layout)
        stageChanged()
        refocusStage()
        syncScenes()
        if let u, stage.stage(for: u)?.emptySlots.isEmpty == false { onPickSlot(u, nil) }
    }

    /// 谁有资格上台、谁排前面：
    /// 1. 和主位窗口「经常一起用」的（本机习惯，来回切换次数）
    /// 2. 住在这块屏上的
    /// 3. 最近用过的
    func stageCandidates(for u: String?) -> [WindowInfo] {
        let main = u.flatMap { stage.stage(for: $0)?.windows.first }
        let all = mruOrder().filter { !stage.isOnStage($0.id) && stage.stageable($0) }
        var together: [UInt32: Int] = [:]
        if let main {
            for (a, b, n) in habits.coUsage(windows) where a == main || b == main { together[a == main ? b : a] = n }
        }
        return all.enumerated().sorted { x, y in
            let cx = together[x.element.id] ?? 0, cy = together[y.element.id] ?? 0
            if (cx >= 2) != (cy >= 2) { return cx >= 2 }
            if cx >= 2 && cy >= 2 && cx != cy { return cx > cy }
            let hx = stage.homeDisplay(x.element.id) == u || x.element.displayUUID == u
            let hy = stage.homeDisplay(y.element.id) == u || y.element.displayUUID == u
            return hx != hy ? hx : x.offset < y.offset
        }.map(\.element)
    }

    /// 把窗口放进某个格子（原来的退到后台；它本来在别的格子就互换）
    func assignStageSlot(display u: String, slot: Int, with w: WindowInfo) {
        stage.present(w, on: u, slot: slot, focus: false)
        stageChanged()
        refocusStage()
        syncScenes()
    }

    func clearStageSlot(display u: String, slot: Int) { stage.clear(display: u, slot: slot); stageChanged(); refocusStage(); syncScenes() }

    /// Weft 自己换下了「正拿着键盘焦点」的窗口时：焦点还停在已经退到后台的窗口上，
    /// 这时再 ⌘Tab 到同一个 App，系统认为焦点没变，什么都不会发生。所以把焦点交给台上当前格子的窗口
    func refocusStage() {
        guard stageActive else { return }
        if let f = system.focusedWindowID(), stage.isOnStage(f) || !stash.isStashed(f) { return }
        guard let u = stage.currentDisplay(), let st = stage.stage(for: u), let id = st.slots[st.active] ?? st.windows.first else { return }
        system.focus(id)
        lastStageFocus = id
    }

    func toggleSlotLock(display u: String, slot: Int) {
        stage.toggleLock(display: u, slot: slot)
        let on = stage.stage(for: u)?.locked.contains(slot) == true
        Toast.show(on ? "🔒 锁住了：切别的窗口不会换掉这个格子" : "🔓 解锁了", seconds: 1.2)
        stageRevision += 1
    }

    /// 由 AppDelegate 接上：在屏幕上的格子里弹出候选（slot 为 nil = 第一个空格子）
    var onPickSlot: (String, Int?) -> Void = { _, _ in }

    func cycleStageRatio(display: String? = nil) {
        let u = display ?? stage.currentDisplay()
        guard var spec = stage.stage(for: u)?.spec, !spec.ratioChoices.isEmpty else { return }
        let i = spec.ratioChoices.firstIndex { abs($0 - spec.ratio) < 0.01 } ?? -1
        spec.ratio = spec.ratioChoices[(i + 1) % spec.ratioChoices.count]
        stage.setSpec(spec, display: u)
        stageChanged()
        syncScenes()
    }

    func mirrorStage(display: String? = nil) {
        let u = display ?? stage.currentDisplay()
        guard var spec = stage.stage(for: u)?.spec else { return }
        spec.mirrored.toggle()
        stage.setSpec(spec, display: u)
        stageChanged()
        syncScenes()
    }

    func swapStage() { stage.swapMain(); stageChanged(); syncScenes() }

    func dismissFromStage(_ id: UInt32) { stage.dismiss(id); stageChanged(); refocusStage(); syncScenes() }

    // MARK: 事情

    func enter(_ c: WorkContext, focusMode: Bool = false) {
        if c.plan?.count == 1 { switchScene(c, on: nil); return }
        if c.plan != nil, applyPlan(c) { return }
        let members = resolved(c)
        guard !members.isEmpty else { Toast.show("「\(c.name)」的窗口都已关闭"); return }
        if stageActive || focusMode {
            // 舞台：把这件事最近用过的 1~3 个窗口请上台，其余退到后台
            let order = habits.mru
            let ranked = members.sorted { (order.firstIndex(of: $0.id) ?? 999) < (order.firstIndex(of: $1.id) ?? 999) }
            let u = stage.currentDisplay() ?? profile.main?.uuid ?? ""
            let wide = (profile.display(uuid: u)?.visible.width ?? 0) >= 1800
            let n = min(ranked.count, wide ? 3 : 2)
            let spec = n == 1 ? StageSpec(.focus) : n == 2 ? StageSpec(.split, ratio: 0.6) : StageSpec(.mainStack)
            stage.apply(scene: [(u, spec, ranked.prefix(n).map(\.id))])
            if !stageActive { beginStage() } else { stageChanged() }
            Toast.show("\(c.emoji) 舞台：「\(c.name)」· 其余 \(members.count - n) 个在后台")
            return
        }
        engine.undo.push("进入：\(c.name)", windows: windows)
        for w in members where stash.isStashed(w.id) { stash.unstash(w.id, focus: false) }
        stashed = stash.entries
        if let saved = c.layouts[profile.fingerprint] {
            let layout = Layout(fingerprint: profile.fingerprint, profile: profile, windows: saved, savedAt: Date(), manual: true)
            Executor.apply(LayoutPlanner.plan(layout: layout, windows: members, profile: profile), using: system)
        }
        for w in members.reversed() { system.setMinimized(w.id, false); system.focus(w.id) }
        Toast.show("\(c.emoji) 进入「\(c.name)」· \(members.count) 个窗口")
    }

    func rememberLayout(_ c: WorkContext) {
        guard let i = contexts.firstIndex(where: { $0.id == c.id }) else { return }
        let members = resolved(c)
        contexts[i].layouts[profile.fingerprint] = LayoutPlanner.capture(windows: members, profile: profile, manual: true).windows
        contexts[i].members = members.map(ContextResolver.member)
        saveContexts()
        Toast.show("📐 已记住「\(c.name)」在当前屏幕组合下的摆放")
    }

    func add(_ w: WindowInfo, to c: WorkContext) {
        for j in contexts.indices { contexts[j].members.removeAll { ContextResolver.resolve([$0], in: [w]).count == 1 } }
        if let i = contexts.firstIndex(where: { $0.id == c.id }) { contexts[i].members.append(ContextResolver.member(w)) }
        saveContexts()
    }

    func remove(_ w: WindowInfo, from c: WorkContext) {
        guard let i = contexts.firstIndex(where: { $0.id == c.id }) else { return }
        contexts[i].members.removeAll { ContextResolver.resolve([$0], in: [w]).count == 1 }
        saveContexts()
    }

    func delete(_ c: WorkContext) {
        contexts.removeAll { $0.id == c.id }
        saveContexts()
    }

    func saveContexts() {
        var db = ContextDB()
        db.contexts = contexts
        db.pinned = pinned
        // 组合里引用的场景被删了：那一块去掉，剩不到两块的组合也去掉
        let ids = Set(contexts.map(\.id))
        combos = combos.compactMap { c in
            var c = c
            c.parts.removeAll { !ids.contains($0.sceneID) }
            return c.parts.count >= 2 ? c : nil
        }
        db.combos = combos
        store.save(db, "contexts.json")
        objectWillChange.send()
    }

    // MARK: AI

    /// 没配置模型就去设置页
    private func requireAI() -> Bool {
        if aiConfig.isConfigured { return true }
        Toast.show("先选一个 AI 模型（Magpie / DeepSeek / 通义…）", seconds: 3)
        NotificationCenter.default.post(name: .init("WeftOpenSettings"), object: "ai")
        return false
    }

    @Published var deskSummary: String?

    /// AI 整理桌面：看所有桌面上的窗口，整理成几个能一键摆出来的场景
    func organize() {
        guard !organizing, requireAI() else { return }
        organizing = true
        aiMessage = nil
        refresh(captureThumbs: false)
        let cands = windows.filter { ($0.axAvailable || !$0.title.isEmpty) && $0.frame.width >= 300 && $0.frame.height >= 200 && !isFloating($0.bundleID) }
        let now = Date()
        var days: [UInt32: Double] = [:], mins: [UInt32: Double] = [:]
        for w in cands {
            if let l = habits.lastFocused(w), l > .distantPast { days[w.id] = now.timeIntervalSince(l) / 86400 }
            mins[w.id] = habits.focusMinutes(w)
        }
        let map = DeskMap.read(profile: profile)
        var input = Organizer.Input(windows: cands, profile: profile, coUsage: habits.coUsage(cands), minutes: mins,
                                    lastUsedDays: days, desktops: DeskMap.locations(map), redact: Set(aiConfig.redactTitlesFor),
                                    memory: memory.promptLines)
        input.request = organizeRequest
        input.floating = settings.floatingApps.map { appName(bundleID: $0) }
        input.existing = scenes.map { c in
            ["name": c.name, "display": c.home.map(DisplayProfile.roleName) ?? "没归屏",
             "apps": (c.plan?.first?.members ?? []).filter { !$0.bundleID.isEmpty }.map { appName(bundleID: $0.bundleID) }] as [String: Any]
        }
        for w in cands { if let m = stage.learnedMin[w.id] { input.minWidth[w.id] = Double(m) } }
        let organizer = Organizer(config: aiConfig)
        Task { @MainActor in
            defer { self.organizing = false }
            do {
                let advice = try await organizer.propose(input)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { self.proposal = advice.proposals }
                // App 名换回 bundleID
                self.proposedFloating = advice.floatingApps.compactMap { n in cands.first { $0.appName == n }?.bundleID }
                    .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                self.floatingReason = advice.floatingReason
                self.deskSummary = advice.summary.isEmpty ? nil : advice.summary
                if advice.proposals.isEmpty { self.aiMessage = "AI 没整理出合适的场景" }
            } catch {
                self.aiMessage = "AI 整理失败：\(error)"
            }
        }
    }

    /// 保存场景（替换以前的「事情」）
    func acceptProposal() {
        guard let p = proposal else { return }
        var next: [WorkContext] = []
        for (i, prop) in p.enumerated() {
            let members = prop.windowIDs.compactMap { window($0) }.map(ContextResolver.member)
            let plan: [ScenePlacement] = prop.scenes.compactMap { sc in
                guard profile.displays.indices.contains(sc.displayIndex) else { return nil }
                let ms = sc.windowIDs.compactMap { window($0) }.map(ContextResolver.member)
                return ms.isEmpty ? nil : ScenePlacement(displayUUID: profile.displays[sc.displayIndex].uuid, displayIndex: sc.displayIndex, spec: sc.spec, members: ms, name: sc.name)
            }
            var c = contexts.first(where: { $0.name == prop.name }) ?? WorkContext(name: prop.name, emoji: prop.emoji, color: i, members: members)
            c.members = members
            c.emoji = prop.emoji
            c.plan = plan.isEmpty ? nil : plan
            next.append(c)
        }
        var split = SceneBook.split(next)
        // AI 给的跨屏场景 = 这几块要一起看：拆开后绑在一起（切一块，另一块跟着切）
        for i in split.combos.indices { split.combos[i].linked = true; split.combos[i].emoji = "🔗" }
        let newIDs = Set(split.contexts.map(\.id))
        let linkedIDs = Set(split.combos.flatMap { $0.parts.map(\.sceneID) })
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            // 合并：同名的覆盖，别的已有场景都留着（以前整个替换，你手建的场景会被冲掉）
            contexts = contexts.filter { !newIDs.contains($0.id) } + split.contexts
            for j in combos.indices where combos[j].isLinked { combos[j].parts.removeAll { linkedIDs.contains($0.sceneID) } }
            combos = combos.filter { old in !split.combos.contains { $0.name == old.name } } + split.combos
            proposal = nil
        }
        // 新场景归屏：按 AI 摆的那块屏
        for i in contexts.indices where newIDs.contains(contexts[i].id) {
            if let u = contexts[i].plan?.first?.displayUUID, let r = profile.role(of: u) { contexts[i].home = r }
        }
        saveContexts()
        let floats = proposedFloating
        proposedFloating = []
        for b in floats { setFloating(b, true, quiet: true) }
        let fl = floats.isEmpty ? "" : " · 🪶 " + floats.map { appName(bundleID: $0) }.joined(separator: "、") + " 设成随手窗口"
        Toast.show("✨ 加了 \(split.contexts.count) 个场景" + (split.combos.isEmpty ? "" : "，\(split.combos.count) 组绑定") + fl, seconds: 3)
    }

    /// 按场景的版式摆上舞台
    func applyPlan(_ c: WorkContext) -> Bool {
        guard let plan = c.plan, !plan.isEmpty else { return false }
        refresh(captureThumbs: false)
        var scene: [(display: String, spec: StageSpec, windows: [UInt32])] = []
        var used = Set<UInt32>()
        for pl in plan {
            let d = pl.displayUUID.flatMap { profile.display(uuid: $0) }
                ?? (profile.displays.indices.contains(pl.displayIndex) ? profile.displays[pl.displayIndex] : profile.main)
            guard let d, !scene.contains(where: { $0.display == d.uuid }) else { continue }
            var ids: [UInt32] = []
            for m in pl.members {
                if let w = ContextResolver.resolve([m], in: windows.filter { !used.contains($0.id) && $0.axAvailable }).first {
                    ids.append(w.id); used.insert(w.id)
                }
            }
            guard !ids.isEmpty else { continue }
            scene.append((d.uuid, StageGeometry.effective(pl.spec, filled: ids.count), ids))
        }
        guard !scene.isEmpty else { return false }
        stage.apply(scene: scene)
        if !stageActive { beginStage() } else { stageChanged() }
        if let sig = currentCombo()?.signature, contexts.contains(where: { $0.id == c.id }) { sceneBySig[sig] = c.id }
        Toast.show("\(c.emoji) \(c.name)")
        return true
    }

    /// 去掉 AI 建议里的一个场景
    func dropProposal(_ name: String) {
        withAnimation { proposal?.removeAll { $0.name == name } }
        if proposal?.isEmpty == true { discardProposal() }
    }

    func discardProposal() { withAnimation { proposal = nil }; proposedFloating = [] }

    /// 先摆出来看看（不保存）
    func tryProposal(_ p: ContextProposal) {
        refresh(captureThumbs: false)
        let scene = p.scenes.compactMap { sc -> (display: String, spec: StageSpec, windows: [UInt32])? in
            guard profile.displays.indices.contains(sc.displayIndex) else { return nil }
            let ids = sc.windowIDs.filter { window($0)?.axAvailable == true }
            return ids.isEmpty ? nil : (profile.displays[sc.displayIndex].uuid, StageGeometry.effective(sc.spec, filled: ids.count), ids)
        }
        guard !scene.isEmpty else { Toast.show("这个场景的窗口在别的桌面上，先「合并成每屏 1 个」再摆"); return }
        stage.apply(scene: scene)
        if !stageActive { beginStage() } else { stageChanged() }
        Toast.show("\(p.emoji) 试摆：\(p.name) · ⌘K 回到整理")
    }

    // MARK: 记忆

    private var comboSig = ""
    private var comboSince = Date()
    private var comboLogged = false
    /// 用场景摆出来的组合：签名 → 场景 id
    private var sceneBySig: [String: String] = [:]

    /// 现在舞台上的组合
    func currentCombo() -> ComboEntry? {
        guard stageActive else { return nil }
        var parts: [ComboEntry.Part] = []
        for (i, d) in profile.displays.enumerated() {
            guard let st = stage.stage(for: d.uuid) else { continue }
            let ms = st.windows.compactMap { window($0) }.map(ContextResolver.member)
            if !ms.isEmpty { parts.append(.init(displayIndex: i, layout: st.spec.layout, members: ms)) }
        }
        return parts.isEmpty ? nil : ComboEntry(parts: parts, at: Date(), minutes: 0)
    }

    /// 同一组窗口在舞台上稳定摆了 3 分钟：记一笔
    private func comboTick() {
        guard tick % 5 == 0, let c = currentCombo() else { return }
        let sig = c.signature
        if sig != comboSig { comboSig = sig; comboSince = Date(); comboLogged = false; return }
        let mins = Date().timeIntervalSince(comboSince) / 60
        guard !comboLogged, mins >= 3 else { return }
        comboLogged = true
        var e = c
        e.at = comboSince
        e.minutes = mins
        e.sceneID = sceneBySig[sig]
        memory.log(e)
        memoryRevision += 1
    }

    private func autoDigest() {
        guard aiConfig.isConfigured, memory.enabled, !digesting,
              Date().timeIntervalSince(memory.db.lastDigest ?? .distantPast) > 20 * 3600,
              habits.db.windows.values.reduce(0, { $0 + $1.focusSeconds }) > 3600 else { return }
        digestMemory(silent: true)
    }

    /// 让 AI 复盘：把本机统计写成几句记忆笔记
    func digestMemory(silent: Bool = false) {
        guard !digesting else { return }
        guard aiConfig.isConfigured else { if !silent { _ = requireAI() }; return }
        digesting = true
        let stats = MemoryStats.build(habits: habits.db, combos: memory.patterns(minCount: 2),
                                      scenes: Dictionary(contexts.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }),
                                      redact: Set(aiConfig.redactTitlesFor))
        let mine = memory.notes.filter { $0.source == .user }.map(\.text)
        let advisor = MemoryAdvisor(config: aiConfig)
        Task { @MainActor in
            defer { self.digesting = false; self.memoryRevision += 1 }
            do {
                let notes = try await advisor.digest(stats: stats, userNotes: mine)
                self.memory.replaceAINotes(notes)
                if !silent { Toast.show("🧠 记住了 \(notes.count) 条习惯") }
            } catch {
                if !silent { Toast.show("AI 复盘失败：\(error)") }
            }
        }
    }

    /// 侧栏「此刻」：这个时间你通常在用的摆法 / 常这样摆但还没存成场景
    enum Moment {
        case scene(WorkContext, MemoryStore.Pattern)
        case routine(MemoryStore.Pattern)
        case save(MemoryStore.Pattern)
    }

    func moment() -> Moment? {
        guard memory.enabled else { return nil }
        let current = currentCombo()?.signature
        if let r = memory.routine(), r.signature != current {
            if let id = r.sceneID, let c = contexts.first(where: { $0.id == id }) { return .scene(c, r) }
            return .routine(r)
        }
        let saved = Set(contexts.compactMap { c in c.plan.map { plan in
            plan.flatMap { $0.members.map { "\($0.bundleID)|\(MemoryStore.normalize($0.title))" } }.sorted().joined(separator: "&")
        } })
        if let p = memory.patterns(minCount: 3).first(where: { $0.sceneID == nil && !saved.contains($0.signature) && !memory.isDismissed("save:" + $0.signature) }) {
            return .save(p)
        }
        return nil
    }

    func dismissMoment(_ m: Moment) {
        switch m {
        case .scene(_, let p), .routine(let p): memory.dismiss("routine:" + p.signature)
        case .save(let p): memory.dismiss("save:" + p.signature)
        }
        memoryRevision += 1
    }

    private func plan(from p: MemoryStore.Pattern) -> [ScenePlacement] {
        p.sample.parts.map { part in
            ScenePlacement(displayUUID: profile.displays.indices.contains(part.displayIndex) ? profile.displays[part.displayIndex].uuid : nil,
                           displayIndex: part.displayIndex, spec: StageSpec(part.layout), members: part.members)
        }
    }

    /// 按记下来的摆法摆出来
    func applyPattern(_ p: MemoryStore.Pattern) {
        var c = WorkContext(name: "上次的摆法", emoji: "🕘", color: 0, members: p.sample.parts.flatMap(\.members))
        c.plan = plan(from: p)
        if !applyPlan(c) { Toast.show("这些窗口现在没开") }
    }

    /// 存成场景（名字先用 App 名，之后可以在总控里改）
    func savePattern(_ p: MemoryStore.Pattern) {
        let apps = p.sample.parts.flatMap(\.members).map { $0.bundleID.split(separator: ".").last.map(String.init) ?? "" }
        let names = p.sample.parts.flatMap(\.members).compactMap { m in windows.first { $0.bundleID == m.bundleID }?.appName }
        let name = (names.isEmpty ? apps : names).prefix(3).joined(separator: " + ")
        var c = WorkContext(name: name, emoji: "📌", color: contexts.count, members: p.sample.parts.flatMap(\.members))
        c.plan = plan(from: p)
        let split = SceneBook.split([c])
        contexts.append(contentsOf: split.contexts)
        combos.append(contentsOf: split.combos)
        saveContexts()
        sceneBySig[p.signature] = c.id
        memory.dismiss("save:" + p.signature)
        memoryRevision += 1
        Toast.show("📌 存成场景「\(name)」· 在总控里点它一键摆出来")
    }

    // MARK: 推荐编号

    /// 空着的数字推荐给最常用、还没编号的窗口（每个窗口只推荐一次）
    func slotSuggestions() -> [Int: WindowInfo] {
        let taken = Set(windows.compactMap { slots.slot(of: $0.id) != nil ? $0.id : nil })
        let empty = SlotStore.range.filter { if case .empty = slots.resolve($0, windows: windows) { return true }; return false }
        let ranked = windows.filter { !taken.contains($0.id) && $0.axAvailable && habits.focusMinutes($0) >= 5 }
            .sorted { habits.focusMinutes($0) > habits.focusMinutes($1) }
        var out: [Int: WindowInfo] = [:]
        var seenApps = Set<String>()
        var it = ranked.makeIterator()
        for n in empty {
            // 同一个 App 只推荐一个窗口（微信一个号码就够）
            while let w = it.next() {
                if seenApps.insert(w.bundleID).inserted { out[n] = w; break }
            }
        }
        return out
    }

    /// 用推荐编号：钉上并切过去
    func acceptSlotSuggestion(_ n: Int) {
        guard let w = slotSuggestions()[n] else { return }
        pinSlot(n, window: w)
        focus(w)
    }

    // MARK: 桌面

    @Published var deskMap: [DeskDisplay] = []
    @Published var deskBusy = false

    func refreshDeskMap() { deskMap = DeskMap.read(profile: system.profile()) }

    /// 删掉空桌面（当前桌面不删）
    func removeEmptyDesktops() {
        refreshDeskMap()
        runDesktopRemoval(deskMap.map { d in d.spaces.filter { $0.isEmpty && !$0.isCurrent }.map(\.index) }, label: "空桌面")
    }

    /// 每块屏只留当前桌面：其他桌面删掉，上面的窗口由系统挪过来
    func mergeDesktops() {
        refreshDeskMap()
        runDesktopRemoval(deskMap.map { d in d.spaces.filter { !$0.isCurrent && !$0.isFullscreen }.map(\.index) }, label: "桌面")
    }

    private func runDesktopRemoval(_ plan: [[Int]], label: String) {
        let total = plan.reduce(0) { $0 + $1.count }
        guard total > 0, !deskBusy else { return }
        deskBusy = true
        tidyVisible = false
        onHideHub()
        MissionControl.removeDesktops(plan) { [weak self] n in
            guard let self else { return }
            self.deskBusy = false
            self.refreshDeskMap()
            self.refresh(captureThumbs: false)
            Toast.show(n > 0 ? "🗂 删掉了 \(n) 个\(label)" : "没能删掉桌面（调度中心没响应），可以手动在调度中心里点「×」", seconds: 3)
        }
    }

    var onHideHub: () -> Void = {}

    /// AI 排布：给出 1~3 套舞台方案
    // MARK: 整理

    @Published var tidyVisible = false
    @Published var tidyItems: [TidyItem] = []
    @Published var tidyThinking = false
    @Published var tidySummary: String?

    func tidy() {
        refreshDeskMap()
        arrangeVisible = false
        tidyVisible = true
        refresh(captureThumbs: false)
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .map { RunningApp(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "", isActive: $0.isActive) }
        let wins = windows.filter { !stash.isStashed($0.id) && !stage.isOnStage($0.id) }
        tidyItems = TidyRules.scan(windows: wins, apps: apps, focusedID: currentWindow?.id,
                                   lastFocused: { [habits] in habits.lastFocused($0) })
        tidySummary = nil
        tidyWithAI()
    }

    func tidyWithAI() {
        guard aiConfig.isConfigured, !tidyThinking else { return }
        tidyThinking = true
        let wins = windows.filter { !stash.isStashed($0.id) && !stage.isOnStage($0.id) && $0.axAvailable }
        let now = Date()
        var days: [UInt32: Double] = [:], mins: [UInt32: Double] = [:]
        for w in wins {
            if let l = habits.lastFocused(w), l > .distantPast { days[w.id] = now.timeIntervalSince(l) / 86400 }
            mins[w.id] = habits.focusMinutes(w)
        }
        let advisor = TidyAdvisor(config: aiConfig)
        let focused = currentWindow?.id, recent = habits.mru
        Task { @MainActor in
            defer { self.tidyThinking = false }
            do {
                let a = try await advisor.advise(windows: wins, focused: focused, recent: recent, lastUsedDays: days,
                                                 minutes: mins, redact: Set(self.aiConfig.redactTitlesFor), memory: self.memory.promptLines)
                let have = Set(self.tidyItems.map(\.id))
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    // 规则已经覆盖的窗口：用 AI 的理由补充；新的追加在后面
                    for it in a.items {
                        if let i = self.tidyItems.firstIndex(where: { $0.id == it.id }) {
                            if !it.reason.isEmpty { self.tidyItems[i].reason += " · AI：\(it.reason)" }
                        } else if !have.contains(it.id) { self.tidyItems.append(it) }
                    }
                    self.tidySummary = a.summary.isEmpty ? nil : a.summary
                }
            } catch {
                self.tidySummary = "AI 判断失败：\(error)（规则建议仍然可用）"
            }
        }
    }

    /// 执行勾选的整理项
    func runTidy() {
        let picked = tidyItems.filter(\.checked)
        var n = (close: 0, stash: 0, min: 0, quit: 0)
        let live = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for it in picked {
            switch it.action {
            case .close: if let id = it.windowID, system.close(id) { n.close += 1 }
            case .stash: if let id = it.windowID, let w = live[id] { stash.stash(displayable(w), original: w.frame); n.stash += 1 }
            case .minimize: if let id = it.windowID, system.setMinimized(id, true) { n.min += 1 }
            case .quit: if NSRunningApplication(processIdentifier: it.pid)?.terminate() == true { n.quit += 1 }
            }
        }
        tidyItems.removeAll { $0.checked }
        stashed = stash.entries
        var parts: [String] = []
        if n.close > 0 { parts.append("关了 \(n.close) 个窗口") }
        if n.stash > 0 { parts.append("\(n.stash) 个收进后台") }
        if n.min > 0 { parts.append("\(n.min) 个最小化") }
        if n.quit > 0 { parts.append("退出 \(n.quit) 个 App") }
        Toast.show(parts.isEmpty ? "没有需要整理的" : "🧹 " + parts.joined(separator: "，") + (n.stash > 0 ? " · 后台的在侧栏里随时叫回" : ""), seconds: 3.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
        if tidyItems.isEmpty { tidyVisible = false }
    }

    func arrange() {
        arrangeVisible = true
        guard !arranging else { return }
        guard aiConfig.isConfigured else { arrangeMessage = "还没有选择 AI 模型。上面的「习惯搭配」不需要 AI，可以先用。"; return }
        arranging = true
        arrangeMessage = nil
        arrangeOptions = nil
        let cands = windows.filter(\.axAvailable).map(displayable)
        var input = ArrangeInput(windows: cands, profile: profile, focused: currentWindow?.id, recent: habits.mru,
                                 coUsage: habits.coUsage(cands),
                                 contexts: contexts.map { ($0.name, resolved($0).map(\.id)) },
                                 redact: Set(aiConfig.redactTitlesFor))
        input.memory = memory.promptLines
        let arranger = Arranger(config: aiConfig)
        Task { @MainActor in
            defer { self.arranging = false }
            do {
                let opts = try await arranger.propose(input)
                withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { self.arrangeOptions = opts }
                if opts.isEmpty { self.arrangeMessage = "AI 没给出可用的方案，换个模型或再试一次" }
            } catch {
                self.arrangeMessage = "AI 排布失败：\(error)"
            }
        }
    }

    func applyArrangement(_ o: ArrangementOption, stageMode: Bool) {
        let ds = profile.displays
        if stageMode {
            stage.apply(scene: o.scenes.compactMap { s in ds.indices.contains(s.displayIndex) ? (ds[s.displayIndex].uuid, s.spec, s.windowIDs) : nil })
            if !stageActive { beginStage() } else { stageChanged() }
        } else {
            arrangeNow(o.scenes.map { (ds.indices.contains($0.displayIndex) ? ds[$0.displayIndex] : nil, $0.spec, $0.windowIDs) })
        }
        arrangeVisible = false
        Toast.show("✨ 已按「\(o.name)」摆好\(stageMode ? "，其余窗口在后台" : "")")
    }

    func refreshModels() {
        let cfg = aiConfig
        guard cfg.isConfigured else { models = []; return }
        Task { @MainActor in
            self.models = (try? await ModelDiscovery.listModels(baseURL: cfg.baseURL, apiKey: cfg.apiKey)) ?? []
        }
    }

    func modelLabel() -> String {
        guard aiConfig.isConfigured else { return "未配置" }
        return models.first(where: { $0.id == aiConfig.model })?.label ?? aiConfig.model
    }
}
