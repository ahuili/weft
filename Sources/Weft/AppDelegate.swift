import AppKit
import Carbon
import WeftAI
import WeftCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    lazy var hub = HubController(model: model)
    lazy var quick = QuickSwitchController(model: model)
    lazy var shelf = ShelfController(model: model)
    lazy var setup = SetupController(model: model)
    let curtain = Curtain()
    lazy var deck = StageDeck(model: model)
    lazy var scenes = SceneSwitcher(model: model)
    lazy var chooser = PlacementChooser(model: model)
    lazy var studio = SceneStudio(model: model)
    let sceneKeys = SceneKeys()
    let sceneSwipe = SceneSwipe()
    var statusItem: NSStatusItem!
    var screenDebounce: DispatchWorkItem?
    /// 上一次的屏幕组合（哪几块屏、各自的位置和尺寸）
    var lastScreenKey = AppDelegate.screenKey()
    static func screenKey() -> String {
        NSScreen.screens.map { s in
            let n = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
            return "\(n)@\(Int(s.frame.minX)),\(Int(s.frame.minY)),\(Int(s.frame.width))x\(Int(s.frame.height))"
        }.sorted().joined(separator: "+")
    }
    var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = WeftGlyph.menuBar(stage: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        model.start()
        model.onSettingsChanged = { [weak self] in
            guard let self else { return }
            self.bindTriggers(); self.shelf.rebuildTriggers()
            // 幕布：开关、样子在设置里一改就生效
            if self.model.stageActive {
                if self.model.settings.stageCurtain != self.curtain.isShown { self.stageChanged(true) }
                else { self.curtain.restyle(self.model.settings.curtainLook) }
            }
        }
        model.onStageChanged = { [weak self] on in self?.stageChanged(on) }
        model.onPickSlot = { [weak self] u, slot in
            guard let self else { return }
            self.hub.hide(); self.shelf.hide()
            // 等窗口排好再弹（格子位置要用新的）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.deck.showPicker(display: u, slot: slot) }
        }
        model.onStageRevision = { [weak self] in self?.deck.refreshPlaceholders() }
        model.onDropPreview = { [weak self] f, label in
            if let f { self?.deck.showDropPreview(f, label: label) } else { self?.deck.hideDropPreview() }
        }
        model.onOfferPlacement = { [weak self] o in self?.chooser.show(o) }
        model.onHideHub = { [weak self] in self?.hub.hide(); self?.shelf.hide() }
        deck.onExit = { [weak self] in self?.model.exitStage() }
        setup.tryHub = { [weak self] in self?.hub.show() }
        setup.tryShelf = { [weak self] in self?.shelf.toggle() }

        let nc = NotificationCenter.default
        nc.addObserver(forName: .init("WeftOpenSettings"), object: nil, queue: .main) { [weak self] n in
            let page = (n.object as? String).flatMap(SetupPage.init(rawValue:))
            MainActor.assumeIsolated { self?.hub.hide(); self?.setup.show(wizard: false, page: page) }
        }
        nc.addObserver(forName: .init("WeftOpenGuide"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setup.show(wizard: true) }
        }
        nc.addObserver(forName: .init("WeftOpenArrange"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.hub.show(arrange: true) }
            }
        }

        DistributedNotificationCenter.default().addObserver(forName: .init("local.weft.ctl"), object: nil, queue: .main) { [weak self] n in
            let cmd = (n.object as? String) ?? ""
            MainActor.assumeIsolated { self?.control(cmd) }
        }

        bindTriggers()
        shelf.rebuildTriggers()
        watchDisplays()
        scenes.openStudio = { [weak self] id, new in self?.studio.show(select: id, new: new) }
        setupSceneGestures()
        // 还没有任何场景：一启动就打开场景工作台，先把场景建好（引导没走完时让引导先来）
        if model.settings.setupDone && model.scenes.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.studio.show() }
        }
        // 被 kill（SIGTERM）时也把后台窗口放回原位，不让窗口「丢」在屏幕外
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        sigterm = term

        if !model.settings.setupDone || !Permissions.accessibility {
            setup.show(wizard: true, page: model.settings.setupDone ? .permissions : .welcome)
        } else {
            Toast.show("Weft 已就绪 · \(model.settings.hubTrigger.display) 打开总控")
        }
        if let show = ProcessInfo.processInfo.environment["WEFT_DEBUG_SHOW"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                switch show {
                case "shelf": self?.shelf.toggle()
                case "guide": self?.setup.show(wizard: true)
                case "settings": self?.setup.show(wizard: false, page: .ai)
                case "stage": self?.model.enterStage()
                case "arrange": self?.hub.show(arrange: true)
                default: self?.hub.show()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        curtain.hide(animated: false)
        model.shutdown()
    }

    /// ⌃← → / 四指左右滑 切场景（只在舞台模式下接管，没开舞台时原样交给系统）
    func setupSceneGestures() {
        let on: () -> Bool = { [weak self] in
            guard let m = self?.model else { return false }
            return m.settings.sceneSwipe && m.stageActive && !m.scenes.isEmpty
        }
        sceneKeys.enabled = on
        sceneKeys.log = { [weak self] m in self?.model.stageLog.append(AppModel.clock.string(from: Date()) + " " + m) }
        // 键盘和触控板一样：换鼠标所在的那块屏（以前跟键盘焦点走，焦点常停在笔记本上，想换扩展屏还得再按 Tab）
        sceneKeys.onOpen = { [weak self] in self?.scenes.peek(0, display: nil) }
        sceneKeys.onStep = { [weak self] d in self?.scenes.peek(d, display: nil) }
        sceneKeys.onTab = { [weak self] in self?.scenes.peekNextDisplay() }
        sceneKeys.onCommit = { [weak self] in self?.scenes.commitPeek() }
        sceneKeys.onCancel = { [weak self] in self?.scenes.cancelPeek() }
        sceneSwipe.enabled = on
        // 触控板：换鼠标所在的那块屏
        sceneSwipe.onStep = { [weak self] d in self?.scenes.peek(d, display: nil) }
        sceneSwipe.onCommit = { [weak self] in self?.scenes.commitPeek() }
        sceneSwipe.onTouch = { [weak self] in self?.scenes.prewarm() }
        sceneKeys.onPress = { [weak self] in self?.scenes.prewarm() }
        sceneKeys.start()
        sceneSwipe.start()
        model.stageLog.append("场景手势：⌃←→ \(sceneKeys.isRunning ? "已接管" : "没接上（缺辅助功能权限？）") · 四指滑 \(sceneSwipe.running ? "已接上" : "没找到触控板")")
    }

    func bindTriggers() {
        let s = model.settings
        TriggerCenter.shared.applySlots(s.slotModifier,
            jump: { [weak self] n in self?.model.jumpSlot(n) },
            pin: { [weak self] n in
                guard let self else { return }
                // 总控开着时钉选中的那个窗口，否则钉当前窗口
                if self.hub.isVisible, let w = self.hub.selectedWindow { self.model.pinSlot(n, window: w) } else { self.model.pinSlot(n) }
            })
        let fails = TriggerCenter.shared.apply(
            hub: s.hubTrigger, stage: s.stageTrigger, quickSwitch: s.quickSwitch, shelf: s.shelfTrigger, scene: s.sceneTrigger,
            onHub: { [weak self] in
                guard let self, !self.quick.isVisible else { return }
                self.hub.toggle()
            },
            onStage: { [weak self] in self?.stageKey() },
            onShelf: { [weak self] in
                guard let self else { return }
                self.hub.hide()
                if self.shelf.isVisible { self.shelf.hide() } else if let s = mouseScreen() { self.shelf.show(on: s, byKey: true) }
            },
            onScene: { [weak self] in
                guard let self else { return }
                self.hub.hide(); self.shelf.hide(); self.deck.hideLayoutPicker()
                self.scenes.toggleOrNext()
            },
            onQuick: { [weak self] d, hold in self?.quick.step(d, hold: hold) })
        if !fails.isEmpty { Toast.show("\(fails.joined(separator: "、")) 被其他 App 占用了，可以在设置里换一个", seconds: 4) }
    }

    /// 舞台快捷键：没开 → 进入并弹出版式盘；开着 → 弹出版式盘；版式盘开着时再按 → 退出舞台
    func stageKey() {
        hub.hide()
        deck.trigger = model.settings.stageTrigger.display
        if !model.stageActive {
            model.enterStage()
            if model.stageActive { deck.showLayoutPicker() }
        } else if deck.isLayoutPickerVisible {
            deck.hideLayoutPicker()
            model.exitStage()
        } else {
            deck.closePicker()
            deck.showLayoutPicker()
        }
    }

    func stageChanged(_ on: Bool) {
        if on { deck.installWheel() } else { deck.hideAll() }
        deck.refreshPlaceholders()
        if on && model.settings.stageCurtain {
            curtain.look = model.settings.curtainLook
            curtain.hint = "舞台模式 · 鼠标碰\(model.settings.shelfEdge == .right ? "右" : "左")边缘看后台 · \(model.settings.stageTrigger.display) 退出"
            curtain.show()
        } else {
            curtain.hide()
        }
        statusItem.button?.image = WeftGlyph.menuBar(stage: on)
    }

    // MARK: 调试指令（weft ctl …）

    func control(_ cmd: String) {
        let a = cmd.split(separator: " ").map(String.init)
        guard let c = a.first else { return }
        let ds = model.system.profile().displays
        func pick(_ i: Int) { if a.count > i, let n = Int(a[i]), ds.indices.contains(n) { model.selectStageDisplay(ds[n].uuid) } }
        switch c {
        case "stage-on": model.enterStage()
        case "stage-off": model.exitStage()
        case "layout":
            pick(2)
            let l = a.count > 1 ? (a[1] == "main-stack" ? StageLayout.mainStack : StageLayout(rawValue: a[1])) : nil
            if let l { model.setStageLayout(l) }
            model.stage.pinnedDisplay = nil
        case "ratio": pick(1); model.cycleStageRatio(); model.stage.pinnedDisplay = nil
        case "mirror": pick(1); model.mirrorStage(); model.stage.pinnedDisplay = nil
        case "swap": pick(1); model.swapStage(); model.stage.pinnedDisplay = nil
        case "show": switch a.count > 1 ? a[1] : "hub" {
            case "shelf": shelf.toggle()
            case "settings": setup.show(wizard: false)
            case "guide": setup.show(wizard: true)
            case "tidy": hub.show(); model.tidy()
            default: hub.show()
            }
        case "slot":
            if a.count > 1, let n = Int(a[1]) {
                let t = Date(); model.jumpSlot(n)
                if a.count > 2 { try? "jump \(Int(Date().timeIntervalSince(t) * 1000))ms\n".write(toFile: a[2], atomically: true, encoding: .utf8) }
            }
        case "swapslot", "assign":
            // assign <屏幕序号> <格子> <窗口ID>：和在候选里点一下是同一个函数
            if a.count > 3, let di = Int(a[1]), ds.indices.contains(di), let slot = Int(a[2]), let id = UInt32(a[3]) {
                model.refresh(captureThumbs: false)
                if let w = model.window(id) { model.assignStageSlot(display: ds[di].uuid, slot: slot, with: w) }
            }
        case "clear":
            if a.count > 2, let di = Int(a[1]), ds.indices.contains(di), let slot = Int(a[2]) { model.clearStageSlot(display: ds[di].uuid, slot: slot) }
        case "lock":
            if a.count > 2, let di = Int(a[1]), ds.indices.contains(di), let slot = Int(a[2]) { model.toggleSlotLock(display: ds[di].uuid, slot: slot) }
        case "stagekey": stageKey()
        case "layoutkey": if a.count > 1, let n = Int(a[1]) { deck.debugPickLayout(n) }
        case "picker":
            // picker <屏幕序号> [格子]
            if a.count > 1, let di = Int(a[1]), ds.indices.contains(di) { deck.showPicker(display: ds[di].uuid, slot: a.count > 2 ? Int(a[2]) : nil) }
        case "pickkey":
            // pickkey <字符>：模拟在候选面板里按键（调试用）
            if a.count > 1 { deck.debugType(a[1]) }
        case "wheel":
            // wheel <屏幕序号> <格子> <步数>：和 ⌥ 滚轮是同一个函数
            if a.count > 3, let di = Int(a[1]), ds.indices.contains(di), let slot = Int(a[2]), let n = Int(a[3]) {
                deck.debugWheel(display: ds[di].uuid, slot: slot, steps: n)
            }
        case "bench":
            var out = ""
            for _ in 0..<3 { let t = Date(); _ = model.system.windows(); out += "windows() \(Int(Date().timeIntervalSince(t) * 1000))ms\n" }
            let t2 = Date(); _ = model.system.focusedWindow(); out += "focusedWindow() \(Int(Date().timeIntervalSince(t2) * 1000))ms\n"
            if a.count > 1 { try? out.write(toFile: a[1], atomically: true, encoding: .utf8) }
        case "pin":
            if a.count > 2, let n = Int(a[1]), let id = UInt32(a[2]) {
                model.refresh(captureThumbs: false)
                if let w = model.window(id) { model.pinSlot(n, window: w) }
            }
        case "hide": hub.hide(); scenes.hide(); shelf.stayOpen = false; shelf.hide(); deck.hideLayoutPicker(); deck.closePicker(); for w in NSApp.windows where w.title.contains("Weft") && w.isVisible { w.close() }
        case "snap":
            // snap <out.png>：截 Weft 自己最大的那个可见面板（调试用）；snap-screen <屏幕序号 1..> <out.png>：截整块屏
            guard a.count >= 2 else { return }
            let w = NSApp.windows.filter { $0.isVisible && $0.frame.width > 200 && $0.level.rawValue >= NSWindow.Level.normal.rawValue && !$0.ignoresMouseEvents }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            guard let w else { return }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", a[1]]
            try? p.run()
        case "snap-screen":
            guard a.count >= 3 else { return }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-D", a[1], a[2]]
            try? p.run()
        case "choose": chooser.debugChoose(a.count > 1 ? Int(a[1]) : nil)
        case "hover":
            // hover <x> <y>：像真鼠标一样移过去（会触发悬停）
            if a.count > 2, let x = Double(a[1]), let y = Double(a[2]) {
                let src = CGEventSource(stateID: .hidSystemState)
                let from = NSEvent.mouseLocation
                let fromCG = CGPoint(x: from.x, y: (NSScreen.screens.first?.frame.height ?? 0) - from.y)
                for k in 1...10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.03) {
                        let t = Double(k) / 10
                        let q = CGPoint(x: fromCG.x + (x - fromCG.x) * t, y: fromCG.y + (y - fromCG.y) * t)
                        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: q, mouseButton: .left)?.post(tap: .cghidEventTap)
                    }
                }
            }
        case "click":
            if a.count > 2, let x = Double(a[1]), let y = Double(a[2]) {
                let src = CGEventSource(stateID: .hidSystemState), p = CGPoint(x: x, y: y)
                CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
                    down?.setIntegerValueField(.mouseEventClickState, value: 1)
                    down?.post(tap: .cghidEventTap)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
                        up?.setIntegerValueField(.mouseEventClickState, value: 1)
                        up?.post(tap: .cghidEventTap)
                    }
                }
            }
        case "drag":
            // drag <x1> <y1> <x2> <y2>：模拟一次真实的鼠标拖动（CG 坐标），测磁吸 / 拉边 / 拖动换位用
            if a.count > 4, let x1 = Double(a[1]), let y1 = Double(a[2]), let x2 = Double(a[3]), let y2 = Double(a[4]) {
                let src = CGEventSource(stateID: .hidSystemState)
                let p1 = CGPoint(x: x1, y: y1), p2 = CGPoint(x: x2, y: y2)
                CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p1, mouseButton: .left)?.post(tap: .cghidEventTap)
                CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p1, mouseButton: .left)?.post(tap: .cghidEventTap)
                for k in 1...20 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 + Double(k) * 0.03) {
                        let t = Double(k) / 20
                        let q = CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t)
                        CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: q, mouseButton: .left)?.post(tap: .cghidEventTap)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p2, mouseButton: .left)?.post(tap: .cghidEventTap)
                }
            }
        case "hubquery":
            // hubquery <文字>：打开总控并填好搜索词（查搜索结果用）
            hub.show(); hub.state.query = a.dropFirst().joined(separator: " "); hub.state.rebuild(model)
        case "appsearch":
            // appsearch <out> <文字>：搜 App 的结果（查搜索用）
            if a.count > 2 {
                AppCatalog.shared.scan()
                let r = AppCatalog.shared.search(a.dropFirst(2).joined(separator: " "), windows: model.windows, limit: 10)
                let out = "total=\(AppCatalog.shared.all.count)\n" + r.map { "\($0.name) | \($0.altName) | \($0.id) | running=\($0.running)" }.joined(separator: "\n")
                try? out.write(toFile: a[1], atomically: true, encoding: .utf8)
            }
        case "keyinfo":
            // keyinfo <out>：哪个窗口是 key、谁有键盘焦点、Weft 自己的窗口都在哪（查「点了没反应」用）
            if a.count > 1 {
                var out = "active=\(NSApp.isActive) key=\(NSApp.keyWindow.map { "\(type(of: $0)) \($0.title) \(NSStringFromRect($0.frame))" } ?? "nil")\n"
                out += "responder=\(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")\n"
                for w in NSApp.windows where w.isVisible { out += "  \(type(of: w)) '\(w.title)' \(NSStringFromRect(w.frame)) level=\(w.level.rawValue) canKey=\(w.canBecomeKey)\n" }
                try? out.write(toFile: a[1], atomically: true, encoding: .utf8)
            }
        case "settle": if a.count > 1 { try? model.stage.settleDebug().write(toFile: a[1], atomically: true, encoding: .utf8) }
        case "minimize": if a.count > 1, let id = UInt32(a[1]) { model.system.setMinimized(id, a.count > 2 ? a[2] != "0" : true) }
        case "focuswin": if a.count > 1, let id = UInt32(a[1]) { model.system.focus(id) }
        case "scenes": scenes.show()
        case "studio": studio.show(select: a.count > 1 ? model.scenes.dropFirst((Int(a[1]) ?? 1) - 1).first?.id : nil)
        case "scenekey": scenes.toggleOrNext()
        case "peek": scenes.peek(a.count > 1 ? (Int(a[1]) ?? 1) : 1, display: nil)
        case "peek-commit": scenes.commitPeek()
        case "ctrlarrow":
            // ctrlarrow <次数> [hold]：由 Weft 自己发 ⌃→（测试事件截取；外部进程没辅助功能权限时发的键会被系统丢掉）
            let n = a.count > 1 ? (Int(a[1]) ?? 1) : 1
            let hold = a.count > 2
            let src = CGEventSource(stateID: .hidSystemState)
            func key(_ c: CGKeyCode, _ down: Bool, _ f: CGEventFlags) {
                let e = CGEvent(keyboardEventSource: src, virtualKey: c, keyDown: down); e?.flags = f; e?.post(tap: .cghidEventTap)
            }
            key(59, true, .maskControl)
            for i in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 + Double(i) * 0.3) {
                    key(124, true, [.maskControl, .maskSecondaryFn, .maskNumericPad]); key(124, false, [.maskControl, .maskSecondaryFn, .maskNumericPad])
                }
            }
            if !hold { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(n) * 0.3 + 1.0) { key(59, false, []) } }
        case "ctrltab":
            let src = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] { let e = CGEvent(keyboardEventSource: src, virtualKey: 48, keyDown: down); e?.flags = .maskControl; e?.post(tap: .cghidEventTap) }
        case "ctrlup":
            let e = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState), virtualKey: 59, keyDown: false); e?.flags = []; e?.post(tap: .cghidEventTap)
        case "sceneapply":
            // sceneapply <序号 1..> ：在切换器里选第 n 个并摆出来
            if a.count > 1, let n = Int(a[1]) { if !scenes.isVisible { scenes.show() }; scenes.apply(n - 1) }
        case "sceneshot":
            if a.count > 1 { scenes.show(); DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { self.control("snap \(a[1])") } }
        case "displays-changed": model.refresh(captureThumbs: false); model.stageDisplaysChanged()
        case "undo": model.undoStage()
        case "heal": model.healStage()
        case "desk-empty": model.removeEmptyDesktops()
        case "mouse":
            // mouse <x> <y>：把鼠标挪到（CG 坐标）
            if a.count > 2, let x = Double(a[1]), let y = Double(a[2]) { CGWarpMouseCursorPosition(CGPoint(x: x, y: y)) }
        case "shelfkey":
            hub.hide()
            if shelf.isVisible { shelf.hide() } else if let s = mouseScreen() { shelf.show(on: s, byKey: true) }
        case "shelf-on":
            // shelf-on <屏幕序号>：在指定屏幕上打开侧栏
            if a.count > 1, let n = Int(a[1]), ds.indices.contains(n),
               let s = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == ds[n].id }) {
                shelf.hide(); shelf.stayOpen = a.count > 2; shelf.show(on: s)
            }
        case "organize": hub.show(); model.tidy(); model.organize()
        case "tryscene":
            if a.count > 1, let n = Int(a[1]), let p = model.proposal, p.indices.contains(n) { hub.hide(); model.tidyVisible = false; model.tryProposal(p[n]) }
        case "homes":
            // homes <out>：每块屏的位置、每个场景归哪块屏
            if a.count > 1 {
                model.refresh(captureThumbs: false)
                var out = "roles=\(model.profile.roleMap) builtin=\(model.profile.displays.map { "\($0.name):\($0.isBuiltin)" })\n"
                for c in model.contexts { out += "\(c.home ?? "-") plan=\(c.plan?.count ?? 0) uuid=\(c.plan?.first?.displayUUID ?? "-") \(c.name)\n" }
                try? out.write(toFile: a[1], atomically: true, encoding: .utf8)
            }
        case "bind":
            // bind <场景名A> <场景名B|-> ：A 和 B（B 所在的屏）绑在一起；- = 解掉 A 的绑定
            if a.count > 2, let x = model.scenes.first(where: { $0.name == a[1] }) {
                if a[2] == "-" { model.unlink(x.id) }
                else if let y = model.scenes.first(where: { $0.name == a[2] }), let r = y.home { model.bind(x.id, role: r, to: y.id) }
            }
        case "switch":
            // switch <场景名>：像切换器那样切（带绑定）
            if a.count > 1, let x = model.scenes.first(where: { $0.name == a[1] }) { model.switchScene(x, on: nil) }
        case "float":
            // float <bundleID> on|off
            if a.count > 2 { model.setFloating(a[1], a[2] == "on") }
        case "organize-ask":
            // organize-ask <要求…>：带着要求让 AI 整理（不保存）
            model.organizeRequest = a.dropFirst().joined(separator: " ")
            model.organize()
        case "proposal":
            // proposal <out>：AI 建议（场景、随手窗口）
            if a.count > 1 {
                var out = "busy=\(model.organizing) msg=\(model.aiMessage ?? "-")\nsummary=\(model.deskSummary ?? "-")\nfloating=\(model.proposedFloating) \(model.floatingReason)\n"
                for p in model.proposal ?? [] {
                    out += "\(p.emoji) \(p.name) — \(p.reason)\n"
                    for sc in p.scenes { out += "   屏\(sc.displayIndex) \(sc.spec.layout) " + sc.windowIDs.map { id in model.window(id).map { "\($0.appName)[\(Int($0.frame.width))]:\($0.title.prefix(24))" } ?? "\(id)" }.joined(separator: " | ") + "\n" }
                }
                out += "combos:\n" + model.combos.map { "  linked=\($0.isLinked) \($0.name)" }.joined(separator: "\n") + "\nfloatingApps=\(model.settings.floatingApps)\n"
                try? out.write(toFile: a[1], atomically: true, encoding: .utf8)
            }
        case "mcstate":
            // mcstate <out>：调度中心开没开、程序坞顶层、各窗口窗口服务器报的位置
            if a.count > 1 {
                var out = "showing=\(MissionControl.isShowing) top=\(MissionControl.dockTop())\n"
                for w in model.system.windows().prefix(40) { out += "\(w.id) \(w.appName) \(w.frame) stashed=\(model.stash.isStashed(w.id))\n" }
                try? out.write(toFile: a[1], atomically: true, encoding: .utf8)
            }
        case "mcprobe":
            // mcprobe <out>：打开调度中心，记下桌面按钮的辅助功能结构（调试删桌面用）
            if a.count > 1 { MissionControl.probe(to: a[1]) }
        case "deskmap":
            if a.count > 1 {
                let map = DeskMap.read(profile: model.system.profile())
                let out = map.map { d in "\(d.name) \(d.uuid.prefix(8)): " + d.spaces.map { "\($0.index)\($0.isCurrent ? "*" : "")[\($0.windows.count)]" }.joined(separator: " ") }.joined(separator: "\n")
                try? out.write(toFile: a[1], atomically: true, encoding: .utf8)
            }
        case "axprobe":
            // axprobe <out>：所有在跑的 App 的 AX 读取情况
            guard a.count > 1 else { return }
            var out = ""
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
                out += "\(app.localizedName ?? "?") policy=\(app.activationPolicy.rawValue) " + model.system.debugRead(app.processIdentifier)
            }
            try? out.write(toFile: a[1], atomically: true, encoding: .utf8)
        case "probe":
            // probe <id> <x> <y> <w> <h> <out>：设一次 frame，分几次读回，看 App 怎么响应
            guard a.count >= 7, let id = UInt32(a[1]), let x = Double(a[2]), let y = Double(a[3]), let w = Double(a[4]), let h = Double(a[5]) else { return }
            let sys = model.system
            func now() -> String { "\(sys.windows().first { $0.id == id }?.frame ?? .zero)" }
            var log = "before \(now())\n"
            sys.setFrame(id, CGRect(x: x, y: y, width: w, height: h))
            log += "t0 \(now())\n"
            for t in [0.2, 0.6, 1.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    log += "t\(t) \(now())\n"
                    try? log.write(toFile: a[6], atomically: true, encoding: .utf8)
                }
            }
        case "dump":
            model.refresh(captureThumbs: false)
            let ds = model.system.profile().displays
            var out = "stage=\(model.stageActive) focusedDisplay=\(model.stage.currentDisplay() ?? "-")\n"
            for (i, d) in ds.enumerated() {
                out += "[\(i)] \(d.name) visible=\(d.visible)\n"
                if let s = model.stage.stage(for: d.uuid) {
                    let fr = model.stage.slotFrames(d.uuid)
                    out += "  spec=\(s.spec.layout.rawValue) ratio=\(s.spec.ratio) mirrored=\(s.spec.mirrored) active=\(s.active) locked=\(s.locked.sorted())\n"
                    for (j, id) in s.slots.enumerated() {
                        let w = id.flatMap { model.window($0) }
                        out += "  slot\(j) \(id.map(String.init) ?? "empty") \(w?.appName ?? "?") \(w?.title.prefix(30) ?? "") actual=\(w?.frame ?? .zero) target=\(j < fr.count ? fr[j] : .zero)\n"
                    }
                }
            }
            out += "stashed=\(model.stash.entries.count)\n"
            for d in ds {
                out += "cands(\(d.name)): \(model.stageCandidates(for: d.uuid).prefix(6).map { "\($0.id):\($0.appName):home=\(model.stage.homeDisplay($0.id)?.prefix(4) ?? "-"):disp=\($0.displayUUID?.prefix(4) ?? "-")" })\n"
            }
            out += "modelWindows=\(model.windows.count)\n"
            for w in NSApp.windows where w.isVisible { out += "own: \(type(of: w)) frame=\(w.frame) level=\(w.level.rawValue)\n" }
            out += "focusedID=\(model.system.focusedWindowID().map(String.init) ?? "nil") front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")\n"
            out += "windows=\(model.system.windows().map { "\($0.id):\($0.appName)" }.joined(separator: ","))\n"
            if a.count > 2, a[2] == "all" {
                for w in model.system.windows() {
                    out += "  \(w.id) \(w.appName) frame=\(w.frame) disp=\(w.displayUUID?.prefix(4) ?? "-") ax=\(w.axAvailable) min=\(w.isMinimized) fixed=\(w.fixedSize ?? false) stageable=\(model.stage.stageable(w)) stashed=\(model.stash.isStashed(w.id)) onStage=\(model.stage.isOnStage(w.id))\n"
                }
            }
            out += "--- stage log ---\n" + model.stageLog.suffix(80).joined(separator: "\n") + "\n"
            let path = a.count > 1 ? a[1] : NSTemporaryDirectory() + "weft-dump.txt"
            try? out.write(toFile: path, atomically: true, encoding: .utf8)
        default: break
        }
    }

    // MARK: 显示器

    func watchDisplays() {
        let trigger: (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.screenDebounce?.cancel()
                let w = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    // 这个通知很吵：最小化一个窗口（Dock 变长）、Dock 自动隐藏、唤醒都会发。
                    // 屏幕没真的变（还是那几块、位置尺寸一样）就只在舞台里原地重排，不退出舞台
                    let key = Self.screenKey()
                    if self.model.stageActive {
                        // 息屏/唤醒时扩展屏会短暂消失又回来：系统把它上面的小窗口（边缘感应条）推到主屏左下角，回来后屏幕「没变」，以前就不重建感应条 → 扩展屏的条叠在笔记本左边缘上抢鼠标
                        if key == self.lastScreenKey { self.model.stage.relayout(); self.model.stageChanged(); self.shelf.rebuildTriggers(); self.deck.refreshPlaceholders(); return }
                        // 真的插拔了屏：舞台不退出。拔掉的屏上的场景先记着（它的窗口被系统挪过来、退到后台，场景随时能在笔记本上摆），
                        // 插回来时那块屏原来的场景自动摆回去
                        self.lastScreenKey = key
                        self.model.refresh(captureThumbs: false)
                        self.model.stageDisplaysChanged()
                        self.shelf.rebuildTriggers()
                        if self.curtain.isShown { self.curtain.show() }
                        self.deck.refreshPlaceholders()
                        return
                    }
                    self.lastScreenKey = key
                    self.model.engine.displaysChanged()
                    self.shelf.rebuildTriggers()
                }
                self.screenDebounce = w
                // 插拔屏后系统会连发通知、还会自己挪窗口，等它安静下来再处理
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main, using: trigger)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main, using: trigger)
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ sel: Selector?) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            menu.addItem(i)
            return i
        }
        let s = model.settings
        if !Permissions.accessibility || !Permissions.screenCapture {
            _ = add("⚠️ 权限未完成，点这里设置…", #selector(openPermissions))
            menu.addItem(.separator())
        }
        _ = add("打开总控（\(s.hubTrigger.display)）", #selector(openHub))
        let st = add(model.stageActive ? "退出舞台模式（\(s.stageTrigger.display)）" : "舞台模式（\(s.stageTrigger.display)）", #selector(toggleStage))
        st.state = model.stageActive ? .on : .off
        _ = add("场景切换…（\(s.sceneTrigger.display)）", #selector(openScenes))
        _ = add("场景工作台（建 / 改场景）…", #selector(openStudio))
        _ = add("打开后台侧栏", #selector(openShelf))
        _ = add("排布建议…", #selector(openArrange))
        _ = add("整理窗口…", #selector(openTidy))
        menu.addItem(.separator())
        let a = add("插拔屏时自动恢复布局", #selector(toggleAutoRestore))
        a.state = model.engine.autoRestore ? .on : .off
        _ = add("AI 模型：\(model.aiConfig.isConfigured ? "\(model.aiConfig.providerName) · \(model.modelLabel())" : "未配置")…", #selector(openAI))
        _ = add("设置…", #selector(openSettings))
        _ = add("重新运行引导…", #selector(openGuide))
        menu.addItem(.separator())
        _ = add("打开数据目录", #selector(openDataDir))
        _ = add("退出 Weft", #selector(quit))
    }

    @objc func openHub() { DispatchQueue.main.async { self.hub.show() } }
    @objc func openShelf() { DispatchQueue.main.async { self.shelf.toggle() } }
    @objc func openArrange() { DispatchQueue.main.async { self.hub.show(arrange: true) } }
    @objc func openTidy() { DispatchQueue.main.async { self.hub.show(); self.model.tidy() } }
    @objc func toggleStage() { model.toggleStage() }
    @objc func openStudio() { studio.show() }
    @objc func openScenes() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.scenes.show() } }
    @objc func toggleAutoRestore() { model.engine.autoRestore.toggle() }
    @objc func openSettings() { setup.show(wizard: false) }
    @objc func openAI() { setup.show(wizard: false, page: .ai) }
    @objc func openPermissions() { setup.show(wizard: false, page: .permissions) }
    @objc func openGuide() { setup.show(wizard: true) }
    @objc func openDataDir() { NSWorkspace.shared.open(Store.shared.dir) }
    @objc func quit() { NSApp.terminate(nil) }
}
