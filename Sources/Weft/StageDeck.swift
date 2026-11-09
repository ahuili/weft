import AppKit
import Carbon
import SwiftUI
import WeftCore

// MARK: - 舞台的操作台
//
// 1. 版式盘：按舞台快捷键，屏幕中间浮出 6 种版式，数字键直接选；再按一次快捷键退出舞台。
// 2. 选窗口：空格子里直接浮出候选窗口（缩略图），点一下或按数字就填进去；打字能搜（支持拼音）。
// 3. 空格子占位：没放窗口的格子里有个淡淡的「＋」，点它就弹候选。
// 4. 转轮：鼠标停在某个格子上，按住 ⌥ 滚动滚轮，这个格子里的窗口原地轮换，松开 ⌥ 就定下来。
// 5. 锁格：锁住的格子不会被 ⌘Tab 切来的窗口换掉。

@MainActor
final class StageDeck {
    let model: AppModel
    init(model: AppModel) { self.model = model }

    var trigger = ""
    var onExit: () -> Void = {}

    // MARK: 版式盘

    private var layoutPanel: KeyPanel?
    private var layoutMonitor: Any?
    let layoutState = LayoutPickerState()

    var isLayoutPickerVisible: Bool { layoutPanel?.isVisible ?? false }

    func showLayoutPicker(display u: String? = nil) {
        closePicker()
        model.refresh(captureThumbs: false)
        // 默认弹在鼠标所在的那块屏：多屏时你看着哪块屏、就操作哪块屏
        let prof = model.system.profile()
        let mouseU = mouseScreen().flatMap { s in
            (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).flatMap { n in prof.displays.first { $0.id == n.uint32Value }?.uuid }
        }
        guard let u = u ?? mouseU ?? model.stage.currentDisplay(), let d = prof.display(uuid: u) else { return }
        model.stage.focus(display: u)
        model.stageRevision += 1
        layoutState.display = u
        layoutState.index = StageLayout.allCases.firstIndex(of: model.stage.stage(for: u)?.spec.layout ?? .focus) ?? 0
        let p = layoutPanel ?? KeyPanel.make(level: .popUpMenu)
        p.contentView = NSHostingView(rootView: LayoutPickerView(model: model, state: layoutState, trigger: trigger,
                                                                 pick: { [weak self] l in self?.pickLayout(l) },
                                                                 exit: { [weak self] in self?.hideLayoutPicker(); self?.onExit() }))
        let size = NSSize(width: 760, height: 250)
        let ns = nsRect(d.frame)
        p.setFrame(NSRect(x: ns.midX - size.width / 2, y: ns.midY - size.height / 2 + 40, width: size.width, height: size.height), display: true)
        layoutPanel = p
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.16; p.animator().alphaValue = 1 }
        if layoutMonitor == nil {
            layoutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, self.isLayoutPickerVisible else { return e }
                return self.handleLayoutKey(e)
            }
        }
    }

    func hideLayoutPicker() {
        if let m = layoutMonitor { NSEvent.removeMonitor(m); layoutMonitor = nil }
        layoutPanel?.orderOut(nil)
    }

    private func handleLayoutKey(_ e: NSEvent) -> NSEvent? {
        let all = StageLayout.allCases
        switch Int(e.keyCode) {
        case kVK_Escape: hideLayoutPicker(); return nil
        case kVK_Return: pickLayout(all[layoutState.index]); return nil
        case kVK_LeftArrow: layoutState.index = (layoutState.index + all.count - 1) % all.count; return nil
        case kVK_RightArrow, kVK_Tab: layoutState.index = (layoutState.index + 1) % all.count; return nil
        default: break
        }
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if let n = Int(ch), n >= 1, n <= all.count { pickLayout(all[n - 1]); return nil }
        if ch == "q" || ch == "0" { hideLayoutPicker(); onExit(); return nil }
        if ch == "m" { model.mirrorStage(display: layoutState.display); return nil }
        if ch == "r" { model.cycleStageRatio(display: layoutState.display); return nil }
        if ch == "z" { model.undoStage(); return nil }
        if ch == "g" || Int(e.keyCode) == kVK_Space { hideLayoutPicker(); model.healStage(); return nil }
        return nil
    }

    func debugPickLayout(_ n: Int) {
        let all = StageLayout.allCases
        if isLayoutPickerVisible, n >= 1, n <= all.count { pickLayout(all[n - 1]) }
    }

    private func pickLayout(_ l: StageLayout) {
        let u = layoutState.display
        hideLayoutPicker()
        model.setStageLayout(l, display: u)
    }

    // MARK: 选窗口

    private var pickPanel: KeyPanel?
    private var pickMonitor: Any?
    let pickState = SlotPickerState()

    var isPickerVisible: Bool { pickPanel?.isVisible ?? false }

    /// 给某个格子选窗口。slot 为 nil = 这块屏第一个空格子（没有空格子就不弹）
    func showPicker(display u: String, slot: Int? = nil) {
        guard let st = model.stage.stage(for: u), let j = slot ?? st.emptySlots.first, st.slots.indices.contains(j) else {
            closePicker(); return
        }
        let frames = model.stage.slotFrames(u)
        guard frames.indices.contains(j) else { return }
        hideLayoutPicker()
        model.refresh(captureThumbs: false)
        pickState.display = u
        pickState.slot = j
        pickState.query = ""
        pickState.index = 0
        reloadCandidates()
        model.thumbnails.refresh(Array(pickState.all.prefix(12).map(\.id)), maxWidth: 360) { [weak self] new in
            self?.model.thumbs.merge(new) { $1 }
        }
        let p = pickPanel ?? KeyPanel.make(level: .floating)
        p.contentView = NSHostingView(rootView: SlotPickerView(model: model, state: pickState,
                                                               pick: { [weak self] w in self?.assign(w) },
                                                               close: { [weak self] in self?.closePicker() }))
        let slotRect = nsRect(frames[j]).insetBy(dx: 16, dy: 16)
        let w = min(slotRect.width, 820), h = min(slotRect.height, 560)
        p.setFrame(NSRect(x: slotRect.midX - w / 2, y: slotRect.midY - h / 2, width: w, height: h), display: true)
        pickPanel = p
        if !p.isVisible { p.alphaValue = 0 }
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
        if pickMonitor == nil {
            pickMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, self.isPickerVisible else { return e }
                return self.handlePickKey(e)
            }
        }
        refreshPlaceholders()
    }

    func closePicker() {
        if let m = pickMonitor { NSEvent.removeMonitor(m); pickMonitor = nil }
        pickPanel?.orderOut(nil)
        refreshPlaceholders()
    }

    private func reloadCandidates() {
        let u = pickState.display
        let width = model.stage.slotFrames(u).dropFirst(pickState.slot).first?.width ?? .greatestFiniteMagnitude
        pickState.width = width
        var c = model.stageCandidates(for: u)
        if !pickState.query.isEmpty { c = FuzzyMatcher.rank(c, query: pickState.query) }
        pickState.all = c
        pickState.items = Array(c.prefix(8))
        pickState.index = min(pickState.index, max(0, pickState.items.count - 1))
    }

    private func handlePickKey(_ e: NSEvent) -> NSEvent? {
        switch Int(e.keyCode) {
        case kVK_Escape:
            if !pickState.query.isEmpty { pickState.query = ""; reloadCandidates() } else { closePicker() }
            return nil
        case kVK_Return:
            if pickState.items.indices.contains(pickState.index) { assign(pickState.items[pickState.index]) }
            return nil
        case kVK_LeftArrow: pickState.index = max(0, pickState.index - 1); return nil
        case kVK_RightArrow: pickState.index = min(max(0, pickState.items.count - 1), pickState.index + 1); return nil
        case kVK_UpArrow: pickState.index = max(0, pickState.index - 4); return nil
        case kVK_DownArrow: pickState.index = min(max(0, pickState.items.count - 1), pickState.index + 4); return nil
        case kVK_Tab:
            // 下一个格子
            if let st = model.stage.stage(for: pickState.display), st.slots.count > 1 {
                showPicker(display: pickState.display, slot: (pickState.slot + 1) % st.slots.count)
            }
            return nil
        case kVK_Delete:
            if !pickState.query.isEmpty { pickState.query.removeLast(); reloadCandidates() }
            return nil
        default: break
        }
        // 没在搜的时候数字键直接选；在搜的时候数字也算搜索词
        if let ch = e.characters, !ch.isEmpty, e.modifierFlags.intersection([.command, .control]).isEmpty {
            if pickState.query.isEmpty, let n = Int(ch), n >= 1, n <= pickState.items.count {
                assign(pickState.items[n - 1]); return nil
            }
            if ch.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                pickState.query += ch
                pickState.index = 0
                reloadCandidates()
            }
        }
        return nil
    }

    private func assign(_ w: WindowInfo) {
        let u = pickState.display, j = pickState.slot
        model.assignStageSlot(display: u, slot: j, with: w)
        // 还有空格子：接着选下一个；没有了就收起
        if let next = model.stage.stage(for: u)?.emptySlots.first {
            showPicker(display: u, slot: next)
        } else {
            closePicker()
            model.system.focus(w.id)
        }
    }

    // MARK: 空格子占位

    private var holders: [String: NSPanel] = [:]

    func refreshPlaceholders() {
        var want: [String: CGRect] = [:]
        if model.stageActive {
            for d in model.system.profile().displays {
                guard let st = model.stage.stage(for: d.uuid) else { continue }
                let fr = model.stage.slotFrames(d.uuid)
                for j in st.emptySlots where fr.indices.contains(j) {
                    // 正在给这个格子选窗口时不画占位
                    if isPickerVisible && pickState.display == d.uuid && pickState.slot == j { continue }
                    want["\(d.uuid)#\(j)"] = fr[j]
                }
            }
        }
        for (k, p) in holders where want[k] == nil { p.orderOut(nil); holders[k] = nil }
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
        for (k, f) in want {
            let parts = k.split(separator: "#")
            let u = String(parts[0]), j = Int(parts[1]) ?? 0
            let p = holders[k] ?? {
                let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                p.level = level
                p.isOpaque = false
                p.backgroundColor = .clear
                p.hasShadow = false
                p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                // 同一个格子的占位只建一次（以前每次舞台刷新都重建一遍 SwiftUI 视图）
                p.contentView = NSHostingView(rootView: EmptySlotView(slot: j, open: { [weak self] in self?.showPicker(display: u, slot: j) }))
                return p
            }()
            let r = nsRect(f)
            if p.frame != r { p.setFrame(r, display: true) }
            if !p.isVisible { p.orderFrontRegardless() }
            holders[k] = p
        }
    }

    // MARK: 转轮（⌥ + 滚轮）

    private var tap: CFMachPort?
    private var wheel: (display: String, slot: Int, ring: [WindowInfo], index: Int)?
    /// 这次转轮是在一摞里翻（不换窗口，只选哪个翻到最上面）
    private var fanMode = false
    private var fan: NSPanel?
    let fanState = WheelState()
    private var accum: CGFloat = 0
    private var lastStep = Date.distantPast
    private var hud: NSPanel?
    let hudState = WheelState()

    func installWheel() {
        guard tap == nil else { return }
        let mask = (1 << CGEventType.scrollWheel.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<StageDeck>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = MainActor.assumeIsolated({ me.tap }) { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let swallow = MainActor.assumeIsolated { me.handleTap(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: cb,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    /// 返回 true = 吃掉这个事件
    private func handleTap(_ type: CGEventType, _ e: CGEvent) -> Bool {
        if type == .flagsChanged {
            if wheel != nil && !e.flags.contains(.maskAlternate) { endWheel() }
            return false
        }
        guard type == .scrollWheel, model.stageActive else { return false }
        let f = e.flags
        guard f.contains(.maskAlternate), !f.contains(.maskCommand), !f.contains(.maskControl), !f.contains(.maskShift) else {
            if wheel != nil { endWheel() }
            return false
        }
        let p = e.location
        if wheel == nil {
            guard let (u, j) = slotAt(p) else { return false }
            guard beginWheel(u, j) else { return true }
        }
        // 触控板（连续）按像素累计；鼠标滚轮按格
        let continuous = e.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        // 手指离开后的惯性滚动不算：以前滑一下会借着惯性连换好几个
        if e.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return true }
        if e.getIntegerValueField(.scrollWheelEventScrollPhase) == 1 { accum = 0 }   // 新的一次滑动从零算
        var step = 0
        if continuous {
            accum += CGFloat(e.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            if abs(accum) >= 90 { step = accum > 0 ? -1 : 1; accum = 0 }
        } else {
            let d = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            if d != 0 { step = d > 0 ? -1 : 1 }
        }
        if step != 0, Date().timeIntervalSince(lastStep) > 0.15 {
            lastStep = Date()
            turn(step)
        }
        return true
    }

    private func beginWheel(_ u: String, _ j: Int) -> Bool {
        // 叠着的格子：在这一摞里翻
        if let st = model.stage.stage(for: u), st.depth(j) > 0, let top = st.slots[j] {
            closePicker()
            let ids = [top] + (st.stacks[top] ?? []).reversed()
            let ring = ids.compactMap { model.window($0) }
            guard ring.count > 1 else { return false }
            fanMode = true
            wheel = (u, j, ring, 0)
            accum = 0
            showFan()
            return true
        }
        fanMode = false
        if model.stage.stage(for: u)?.locked.contains(j) == true { Toast.show("🔒 这个格子锁住了", seconds: 0.9); return false }
        closePicker()
        model.refresh(captureThumbs: false)
        let cur = model.stage.stage(for: u)?.slots[j].flatMap { id in model.window(id) }
        // 已知放不下的宽窗口不进转轮（免得把旁边的窗口挤扁）
        let width = model.stage.slotFrames(u).dropFirst(j).first?.width ?? .greatestFiniteMagnitude
        let ring = ([cur].compactMap { $0 } + model.stageCandidates(for: u).filter { model.stage.fits($0.id, width: width) }).prefix(14)
        guard ring.count > 1 else { Toast.show("没有别的窗口可换", seconds: 0.9); return false }
        // 空格子：第一下就放第一个候选
        wheel = (u, j, Array(ring), cur == nil ? -1 : 0)
        accum = 0
        showHUD()
        return true
    }

    func debugWheel(display u: String, slot j: Int, steps: Int, hold: Bool = false) {
        guard beginWheel(u, j) else { return }
        for _ in 0..<abs(steps) { turn(steps > 0 ? 1 : -1) }
        if !hold { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.endWheel() } }
    }
    func debugEndWheel() { endWheel() }

    func debugType(_ s: String) {
        guard isPickerVisible else { return }
        for ch in s {
            if let n = Int(String(ch)), pickState.query.isEmpty, n >= 1, n <= pickState.items.count { assign(pickState.items[n - 1]); return }
            pickState.query.append(ch)
        }
        pickState.index = 0
        reloadCandidates()
    }

    private func slotAt(_ p: CGPoint) -> (String, Int)? {
        for d in model.system.profile().displays where d.frame.contains(p) {
            guard model.stage.stage(for: d.uuid) != nil else { return nil }
            for (j, f) in model.stage.baseSlotFrames(d.uuid).enumerated() where f.contains(p) { return (d.uuid, j) }
        }
        return nil
    }

    private func turn(_ step: Int) {
        guard let w = wheel else { return }
        turn(to: w.index < 0 ? (step > 0 ? 0 : w.ring.count - 1) : (w.index + step + w.ring.count) % w.ring.count)
    }

    /// 点转轮小框里的图标：直接换成它，定下来
    private func pickInWheel(_ i: Int) {
        guard let w = wheel, w.ring.indices.contains(i) else { return }
        if i != w.index { turn(to: i) }
        endWheel()
    }

    private func turn(to i: Int) {
        guard var w = wheel, w.ring.indices.contains(i) else { return }
        w.index = i
        wheel = w
        if fanMode {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { fanState.index = i }
            return
        }
        let target = w.ring[w.index]
        model.assignStageSlot(display: w.display, slot: w.slot, with: target)
        hudState.ring = w.ring
        hudState.index = w.index
        refreshPlaceholders()
    }

    private func endWheel() {
        guard let w = wheel else { return }
        wheel = nil
        if fanMode {
            fanMode = false
            hideFan()
            let pick = w.ring[max(0, w.index)].id
            if w.index > 0, model.stage.raiseInStack(pick) { model.stageChanged(); model.syncScenes() }
            else { model.system.focus(pick) }
            return
        }
        hud?.orderOut(nil)
        if let id = model.stage.stage(for: w.display)?.slots[w.slot] { model.system.focus(id) }
    }

    /// 一摞窗口斜着展开（像翻唱片），盖在这一格上
    private func showFan() {
        guard let w = wheel, let f = model.stage.baseSlotFrames(w.display).dropFirst(w.slot).first else { return }
        fanState.ring = w.ring
        fanState.index = 0
        model.thumbnails.refresh(w.ring.map(\.id), maxWidth: 700) { [weak self] new in
            self?.model.thumbs.merge(new) { $1 }
        }
        let p = fan ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient, .fullScreenAuxiliary]
            p.contentView = FirstClickHostingView(rootView: StackFanView(model: model, state: fanState, pick: { [weak self] i in self?.pickInWheel(i) }))
            return p
        }()
        p.setFrame(nsRect(f), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        fan = p
    }

    private func hideFan() {
        guard let p = fan else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
    }

    private func showHUD() {
        guard let w = wheel, let f = model.stage.slotFrames(w.display).dropFirst(w.slot).first else { return }
        hudState.ring = w.ring
        hudState.index = max(0, w.index)
        let p = hud ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
            p.contentView = FirstClickHostingView(rootView: WheelHUD(model: model, state: hudState, pick: { [weak self] i in self?.pickInWheel(i) }))
            return p
        }()
        let ns = nsRect(f)
        let size = NSSize(width: min(ns.width - 40, 560), height: 92)
        p.setFrame(NSRect(x: ns.midX - size.width / 2, y: ns.minY + 40, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
        hud = p
    }

    // MARK: 工具

    /// CG（左上原点）→ AppKit（左下原点）
    func nsRect(_ r: CGRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    // MARK: 拖进来：落点预览

    private var dropPanel: NSPanel?
    let dropState = DropState()

    /// 拖着窗口过屏时，在它松手会落下的位置画一个框
    func showDropPreview(_ f: CGRect, label: String) {
        let r = nsRect(f).insetBy(dx: 2, dy: 2)
        dropState.label = label
        if dropPanel == nil {
            let p = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: DropPreviewView(state: dropState))
            p.alphaValue = 0
            dropPanel = p
        }
        guard let p = dropPanel else { return }
        if p.frame != r {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = p.alphaValue == 0 ? 0 : 0.15
                p.animator().setFrame(r, display: true)
            }
        }
        if p.alphaValue < 1 {
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        }
    }

    func hideDropPreview() {
        guard let p = dropPanel, p.alphaValue > 0 else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
    }

    func hideAll() {
        hideDropPreview()
        hideLayoutPicker()
        closePicker()
        endWheel()
        for p in holders.values { p.orderOut(nil) }
        holders.removeAll()
    }
}

// MARK: - 视图

@MainActor
final class LayoutPickerState: ObservableObject {
    @Published var display = ""
    @Published var index = 0
}

struct LayoutPickerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: LayoutPickerState
    let trigger: String
    var pick: (StageLayout) -> Void
    var exit: () -> Void

    var body: some View {
        let _ = model.stageRevision
        let cur = model.stage.stage(for: state.display)
        VStack(spacing: 14) {
            HStack {
                Text("🎭 选个版式").font(.system(size: 15, weight: .bold))
                if model.stageDisplays.count > 1, let n = model.stageDisplays.first(where: { $0.uuid == state.display })?.name {
                    Text("· \(n)").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("数字键选 · R 比例 · M 左右翻转 · \(trigger.isEmpty ? "Q" : "再按 \(trigger)") 退出舞台")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                ForEach(Array(StageLayout.allCases.enumerated()), id: \.element) { i, l in
                    let sel = i == state.index
                    let spec = cur?.spec.layout == l ? cur!.spec : StageSpec(l, mirrored: cur?.spec.mirrored ?? false)
                    Button { pick(l) } label: {
                        VStack(spacing: 8) {
                            LayoutPreview(model: model, spec: spec, windows: cur?.windows ?? [], size: CGSize(width: 100, height: 64))
                            HStack(spacing: 4) {
                                Text("\(i + 1)").font(.system(size: 11, weight: .bold, design: .rounded))
                                    .frame(width: 16, height: 16).background(Circle().fill(sel ? Color.purple : Color.white.opacity(0.15)))
                                Text(l.title).font(.system(size: 12, weight: sel ? .bold : .regular))
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(sel ? Color.purple.opacity(0.25) : Color.white.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(cur?.spec.layout == l ? Color.purple : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0 { state.index = i } }
                }
            }
            HStack {
                Text("乱了？按空格归位 · Z 撤销上一步 · 拖窗口到别的格子换位 · 拉中间的边改比例")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button { model.undoStage() } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.bordered).controlSize(.small).disabled(!model.stage.canUndo)
                Button { model.healStage() } label: { Label("归位", systemImage: "sparkles") }
                    .buttonStyle(.bordered).controlSize(.small)
                Button("退出舞台") { exit() }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 22).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.14)))
    }
}

/// 版式预览：格子里放上现在台上窗口的图标（换版式后它们按顺序留在前面的格子）
struct LayoutPreview: View {
    @ObservedObject var model: AppModel
    let spec: StageSpec
    let windows: [UInt32]
    let size: CGSize

    var body: some View {
        let frames = StageGeometry.frames(spec, in: CGRect(origin: .zero, size: CGSize(width: size.width * 10, height: size.height * 10)), gap: 30)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.25))
            ForEach(Array(frames.enumerated()), id: \.offset) { i, f in
                let w = i < windows.count ? model.window(windows[i]) : nil
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(w != nil ? Color.purple.opacity(i == 0 ? 0.55 : 0.35) : Color.white.opacity(0.08))
                    if let w { Image(nsImage: appIcon(w.pid)).resizable().frame(width: 16, height: 16) }
                    else { Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4)) }
                }
                .frame(width: f.width / 10, height: f.height / 10)
                .offset(x: f.minX / 10, y: f.minY / 10)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

@MainActor
final class SlotPickerState: ObservableObject {
    @Published var display = ""
    @Published var slot = 0
    @Published var query = ""
    @Published var index = 0
    @Published var items: [WindowInfo] = []
    var all: [WindowInfo] = []
    var width: CGFloat = .greatestFiniteMagnitude
}

struct SlotPickerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: SlotPickerState
    var pick: (WindowInfo) -> Void
    var close: () -> Void

    var body: some View {
        let _ = model.stageRevision
        let st = model.stage.stage(for: state.display)
        let occupant = st.flatMap { $0.slots.indices.contains(state.slot) ? $0.slots[state.slot] : nil }.flatMap { model.window($0) }
        let locked = st?.locked.contains(state.slot) == true
        GeometryReader { geo in
            let cols = max(1, min(4, Int((geo.size.width - 40) / 190)))
            let cardW = min(200, (geo.size.width - 40 - CGFloat(cols - 1) * 12) / CGFloat(cols))
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(occupant == nil ? "这个格子放谁？" : "换成…").font(.system(size: 15, weight: .bold))
                    if let o = occupant {
                        Image(nsImage: appIcon(o.pid)).resizable().frame(width: 16, height: 16)
                        Text("现在：\(model.short(o))").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.toggleSlotLock(display: state.display, slot: state.slot) } label: {
                        Label(locked ? "已锁定" : "锁定", systemImage: locked ? "lock.fill" : "lock.open")
                    }.buttonStyle(.bordered).controlSize(.small).help("锁住后，⌘Tab 切来的窗口不会换掉这里")
                    if occupant != nil {
                        Button { model.clearStageSlot(display: state.display, slot: state.slot); close() } label: { Label("空着", systemImage: "rectangle.dashed") }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text(state.query.isEmpty ? "直接打字搜索（拼音也行）· 数字键直接选 · Tab 下一个格子" : state.query)
                        .font(.system(size: 13)).foregroundStyle(state.query.isEmpty ? .tertiary : .primary)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                if state.items.isEmpty {
                    Text(state.query.isEmpty ? "后台没有别的窗口了" : "没找到「\(state.query)」").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(cardW), spacing: 12), count: cols), alignment: .leading, spacing: 12) {
                            ForEach(Array(state.items.enumerated()), id: \.element.id) { i, w in
                                Button { pick(w) } label: {
                                    WindowCard(window: w, thumb: model.thumbs[w.id], selected: i == state.index, accent: .purple,
                                               badge: state.query.isEmpty ? "\(i + 1)" : nil, subtitle: w.appName, width: cardW,
                                               flags: model.stage.fits(w.id, width: state.width) ? [] : ["可能太宽"])
                                }
                                .buttonStyle(.plain)
                                .onHover { if $0 { state.index = i } }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.purple.opacity(0.55), lineWidth: 1.5))
    }
}

struct EmptySlotView: View {
    let slot: Int
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(.white.opacity(hover ? 0.5 : 0.22))
                RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(hover ? 0.08 : 0.03))
                VStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 28, weight: .light))
                    Text("点这里选窗口").font(.system(size: 13, weight: .medium))
                    Text("或鼠标停在这里，按住 ⌥ 滚动").font(.system(size: 11)).opacity(0.7)
                }
                .foregroundStyle(.white.opacity(hover ? 0.85 : 0.45))
            }
            .padding(6)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

@MainActor
final class WheelState: ObservableObject {
    @Published var ring: [WindowInfo] = []
    @Published var index = 0
}

struct WheelHUD: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WheelState
    var pick: (Int) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Array(state.ring.enumerated()), id: \.element.id) { i, w in
                    Image(nsImage: appIcon(w.pid)).resizable()
                        .frame(width: i == state.index ? 34 : 24, height: i == state.index ? 34 : 24)
                        .opacity(i == state.index ? 1 : 0.55)
                        .contentShape(Rectangle())
                        .onTapGesture { pick(i) }
                        .help("\(w.appName) · \(w.title)")
                }
            }
            .animation(.easeOut(duration: 0.12), value: state.index)
            if state.ring.indices.contains(state.index) {
                let w = state.ring[state.index]
                Text("\(w.appName) · \(w.title.prefix(30))  ·  点图标直接换 · 松开 ⌥ 定下来").font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.purple.opacity(0.5)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class DropState: ObservableObject {
    @Published var label = ""
}

/// 落点预览：半透明的紫色框 + 一行字
struct DropPreviewView: View {
    @ObservedObject var state: DropState
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color.purple.opacity(0.18))
            RoundedRectangle(cornerRadius: 14).strokeBorder(Color.purple.opacity(0.85), style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            Text(state.label).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(Color.purple.opacity(0.85)))
        }
    }
}

/// 一摞窗口立体展开：选中的在正中、正对着你，两边的往后斜，滚一下换一个
struct StackFanView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WheelState
    var pick: (Int) -> Void = { _ in }

    var body: some View {
        GeometryReader { g in
            let cw = min(g.size.width * 0.56, 640), ch = min(g.size.height * 0.62, cw * 0.66)
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.35))
                ForEach(Array(state.ring.enumerated()), id: \.element.id) { i, w in
                    let off = Double(i - state.index)
                    card(w, selected: i == state.index)
                        .frame(width: cw, height: ch)
                        .rotation3DEffect(.degrees(off == 0 ? 0 : (off > 0 ? -48 : 48)), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                        .scaleEffect(off == 0 ? 1 : 0.78)
                        .offset(x: off == 0 ? 0 : (off > 0 ? 1 : -1) * (cw * 0.42 + CGFloat(abs(off) - 1) * cw * 0.16))
                        .opacity(abs(off) > 3 ? 0 : 1)
                        .zIndex(10 - abs(off))
                        .onTapGesture { pick(i) }
                }
                VStack {
                    Spacer()
                    Text("⌥ + 滚动 翻 · 松开 ⌥ 翻到最上面 · \(state.index + 1)/\(state.ring.count)")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                        .padding(.bottom, 14)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }

    @ViewBuilder func card(_ w: WindowInfo, selected: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.4))
                if let t = model.thumbs[w.id] {
                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: appIcon(w.pid)).resizable().frame(width: 72, height: 72)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.purple : .white.opacity(0.15), lineWidth: selected ? 3 : 1))
            .shadow(color: .black.opacity(0.5), radius: selected ? 24 : 10, y: 8)
            HStack(spacing: 6) {
                Image(nsImage: appIcon(w.pid)).resizable().frame(width: 18, height: 18)
                Text(w.title.isEmpty ? w.appName : w.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .opacity(selected ? 1 : 0.6)
        }
    }
}
