import AppKit
import SwiftUI
import WeftCore

// MARK: - 场景：Weft 的「桌面」
//
// 一个场景 = 一块屏上的一个版式 + 几个窗口。场景不绑屏幕：摆到哪块屏都行，每块屏各自切换，自由组合。
// 组合 = 几个场景同时摆在几块屏上，记得上次各自在哪块屏；那块屏不在（拔了外接屏）就只摆剩下的，插回来再恢复。

extension AppModel {
    /// 所有场景（只管一块屏的；没摆法的「事情」不算）
    var scenes: [WorkContext] { contexts.filter { $0.plan?.count == 1 } }

    struct SceneSlot {
        var member: WorkContext.Member
        /// 找到的窗口（可能在别的系统桌面上）
        var window: WindowInfo?
        var elsewhere: Bool { window.map { !$0.axAvailable } ?? false }
    }

    /// 场景每个格子现在对应哪个窗口
    func sceneSlots(_ c: WorkContext) -> [SceneSlot] {
        guard let pl = c.plan?.first else { return [] }
        var used = Set<UInt32>()
        return pl.members.map { m in
            // bundleID 为空 = 这一格故意空着
            let w = m.bundleID.isEmpty ? nil : ContextResolver.resolve([m], in: windows.filter { !used.contains($0.id) }).first
            if let w { used.insert(w.id) }
            return SceneSlot(member: m, window: w)
        }
    }

    /// 去掉已经关掉的窗口（故意空着的格子留着）：卡片上画的、摆出来的都是这些
    func liveSlots(_ c: WorkContext) -> [SceneSlot] {
        sceneSlots(c).filter { $0.window != nil || $0.member.bundleID.isEmpty }
    }

    // MARK: 场景归屏

    /// 这块屏的位置（笔记本 / 扩展屏1…）
    func role(of u: String) -> String? { profile.role(of: u) }

    /// 场景所属的那块屏（现在接着的话）
    func homeDisplay(_ c: WorkContext) -> String? { c.home.flatMap { profile.display(forRole: $0)?.uuid } }

    /// 场景属于这块屏吗（没归屏的老场景哪块屏都算）
    func belongs(_ c: WorkContext, to u: String) -> Bool { c.home == nil || c.home == role(of: u) }

    /// 场景所属的屏现在没接（拔掉了）：这时它可以临时摆到别的屏上
    func homeAway(_ c: WorkContext) -> Bool { c.home != nil && homeDisplay(c) == nil }

    /// 某块屏的场景切换器里列哪些：自己的场景，再加上「所属的屏没接」的场景（临时借住）
    func switcherScenes(for u: String) -> [WorkContext] {
        scenes.filter { belongs($0, to: u) } + scenes.filter { homeAway($0) }
            .sorted { DisplayProfile.roleOrder($0.home ?? "") < DisplayProfile.roleOrder($1.home ?? "") }
    }

    /// 场景里的窗口一个都没开着（App 退了 / 窗口全关了）：切换器里不列，场景工作台里还在，开了就回来
    func sceneDormant(_ c: WorkContext) -> Bool {
        let slots = sceneSlots(c).filter { !$0.member.bundleID.isEmpty }
        return !slots.isEmpty && slots.allSatisfy { $0.window == nil }
    }

    /// 老场景还没归屏的：按它上次摆的那块屏归（那块屏现在接着才认得出来）
    func assignHomes() {
        var changed = false
        for i in contexts.indices where contexts[i].home == nil && contexts[i].plan?.count == 1 {
            let u = showingOn(contexts[i].id) ?? contexts[i].plan?.first?.displayUUID
            if let u, let r = profile.role(of: u) { contexts[i].home = r; changed = true }
        }
        if changed { saveContexts() }
    }

    /// 把场景换到另一块屏（之后它就只出现在那块屏的切换器里）
    func moveScene(_ id: String, to r: String) {
        guard let i = contexts.firstIndex(where: { $0.id == id }), contexts[i].home != r else { return }
        contexts[i].home = r
        contexts[i].autoSolo = nil
        for (k, v) in roleShowing where v == id && k != r { roleShowing[k] = nil }
        saveContexts()
        Toast.show("\(contexts[i].emoji) 「\(contexts[i].name)」以后归\(DisplayProfile.roleName(r))", seconds: 1.6)
    }

    /// 这个场景现在摆在哪块屏上（台上正好是它的窗口）
    func sceneShowing(_ c: WorkContext) -> String? {
        guard stageActive else { return nil }
        if let u = showingOn(c.id) { return u }
        let ids = Set(sceneSlots(c).compactMap { $0.window?.axAvailable == true ? $0.window!.id : nil })
        guard !ids.isEmpty else { return nil }
        return profile.displays.first { d in stage.stage(for: d.uuid).map { Set($0.windows) == ids } ?? false }?.uuid
    }

    /// 所有场景里有多少个窗口在别的系统桌面上（摆不出来）
    var scenesElsewhere: Int {
        Set(scenes.flatMap { sceneSlots($0).compactMap { $0.elsewhere ? $0.window?.id : nil } }).count
    }

    private func placement(_ c: WorkContext, on u: String, used: inout Set<UInt32>) -> (display: String, spec: StageSpec, slots: [UInt32?], stacks: [UInt32: [UInt32]])? {
        guard let pl = c.plan?.first else { return nil }
        // 叠放：按格子找到那一格最上面的窗口，再找压在它下面的
        var stacks: [UInt32: [UInt32]] = [:]
        if let st = pl.stacks {
            for (j, slot) in sceneSlots(c).enumerated() where j < st.count && !st[j].isEmpty {
                guard let top = slot.window else { continue }
                var ids: [UInt32] = []
                for m in st[j] {
                    let pool = windows.filter { !used.contains($0.id) && $0.id != top.id && !ids.contains($0.id) && $0.axAvailable }
                    if let w = ContextResolver.resolve([m], in: pool).first { ids.append(w.id) }
                }
                if !ids.isEmpty { stacks[top.id] = ids }
            }
        }
        // 版式和位置照场景的来：在别的桌面上的那一格空着，别的窗口不挪位；已经关掉的窗口不占格子
        let slots = Array(liveSlots(c).map { s -> UInt32? in
            guard let w = s.window, w.axAvailable, !used.contains(w.id), stage.stageable(w) || w.isMinimized else { return nil }
            used.insert(w.id)
            return w.id
        }.prefix(pl.layout.slots))
        guard slots.contains(where: { $0 != nil }) else { return nil }
        stacks = stacks.filter { slots.contains($0.key) }
        for ids in stacks.values { ids.forEach { used.insert($0) } }
        return (u, pl.spec, slots, stacks)
    }

    /// 把场景摆到某块屏上（nil = 现在操作的那块屏）。别的屏不受影响
    @discardableResult
    func applyScene(_ c: WorkContext, on display: String?) -> Bool {
        guard Permissions.accessibility else { Toast.show("需要先授予辅助功能权限"); return false }
        refresh(captureThumbs: false)
        guard let u = display ?? homeDisplay(c) ?? stage.currentDisplay() ?? profile.main?.uuid else { return false }
        var used = Set<UInt32>()
        let slots = sceneSlots(c)
        let away = slots.filter(\.elsewhere).count
        guard let p = placement(c, on: u, used: &used) else {
            let blank = c.plan?.first?.members.allSatisfy(\.bundleID.isEmpty) ?? true
            Toast.show(blank ? "「\(c.name)」还没放窗口 · 在场景工作台里拖几个窗口进去" : away > 0 ? "「\(c.name)」的窗口都在别的系统桌面上 · 合并桌面后才能摆出来" : "「\(c.name)」的窗口都已经关了", seconds: 2.5)
            return false
        }
        stage.applySlots([p])
        if !stageActive { beginStage() } else { stageChanged() }
        markShowing(c.id, on: u)
        refocusStage()
        let name = profile.displays.count > 1 ? (profile.display(uuid: u).map { $0.isBuiltin ? " → 笔记本" : " → \($0.name.prefix(10))" } ?? "") : ""
        Toast.show("\(c.emoji) \(c.name)\(name)" + (away > 0 ? " · \(away) 个窗口在别的桌面上没摆" : ""), seconds: 1.4)
        return true
    }

    /// 摆出一个组合：每个场景回到上次那块屏；屏不够就只摆能摆的
    func applyCombo(_ combo: SceneCombo) {
        refresh(captureThumbs: false)
        // 场景归了屏的，回到自己的屏；没接 / 没归屏的按组合上次的位置
        var taken = Set<String>()
        var pairs: [(WorkContext, String)] = []
        let fallback = SceneBook.assign(combo, to: profile)
        for part in combo.parts {
            guard let c = contexts.first(where: { $0.id == part.sceneID }) else { continue }
            guard let u = homeDisplay(c) ?? fallback.first(where: { $0.sceneID == c.id })?.display, !taken.contains(u) else { continue }
            taken.insert(u)
            pairs.append((c, u))
        }
        let n = applyMany(pairs)
        guard n > 0 else { Toast.show("「\(combo.name)」的窗口现在都摆不出来（关了或在别的桌面上）"); return }
        Toast.show("\(combo.emoji) \(combo.name) · \(n) 块屏", seconds: 1.4)
    }

    /// 把某块屏现在的样子写进场景（编辑场景 = 摆好以后「用现在的样子更新」）
    func updateScene(_ c: WorkContext, from u: String) {
        guard let i = contexts.firstIndex(where: { $0.id == c.id }), let pl = currentPlacement(u) else {
            Toast.show("这块屏上还没有摆窗口"); return
        }
        contexts[i].plan = [pl]
        contexts[i].members = pl.members.filter { !$0.bundleID.isEmpty }
        contexts[i].autoSolo = nil
        saveContexts()
        Toast.show("✏️ 「\(c.name)」已更新为现在的摆法", seconds: 1.4)
    }

    /// 把某块屏现在的样子存成新场景
    @discardableResult
    func saveScene(from u: String, name: String? = nil) -> WorkContext? {
        guard let pl = currentPlacement(u) else { Toast.show("这块屏上还没有摆窗口"); return nil }
        let apps = pl.members.compactMap { m in windows.first { $0.bundleID == m.bundleID }?.appName }
        var seen = Set<String>()
        let auto = apps.filter { seen.insert($0).inserted }.prefix(2).joined(separator: " + ")
        var c = WorkContext(name: name ?? (auto.isEmpty ? "新场景" : auto), emoji: "🎬", color: contexts.count, members: pl.members.filter { !$0.bundleID.isEmpty })
        c.plan = [pl]
        c.home = role(of: u)
        contexts.append(c)
        saveContexts()
        Toast.show("🎬 存成场景「\(c.name)」", seconds: 1.4)
        return c
    }

    /// 几块屏现在各自的样子存成一个组合（没对应场景的屏顺手存成新场景）
    func saveComboFromScreens() {
        var parts: [SceneCombo.Part] = []
        for (i, d) in profile.displays.enumerated() {
            guard let st = stage.stage(for: d.uuid), !st.windows.isEmpty else { continue }
            let sc = scenes.first { sceneShowing($0) == d.uuid } ?? saveScene(from: d.uuid)
            if let sc { parts.append(.init(sceneID: sc.id, displayUUID: d.uuid, displayIndex: i)) }
        }
        guard parts.count >= 2 else { Toast.show("至少两块屏上都摆了窗口，才能存成组合"); return }
        let names = parts.compactMap { p in contexts.first { $0.id == p.sceneID }?.name }
        combos.append(SceneCombo(name: names.joined(separator: " + "), emoji: "🖥", parts: parts))
        saveContexts()
        Toast.show("🖥 存成组合「\(names.joined(separator: " + "))」", seconds: 1.6)
    }

    private func currentPlacement(_ u: String) -> ScenePlacement? {
        guard let st = stage.stage(for: u), !st.windows.isEmpty else { return nil }
        guard st.windows.contains(where: { window($0) != nil }) else { return nil }
        var members = st.slots.map { id in id.flatMap { window($0) }.map(ContextResolver.member) ?? WorkContext.Member(bundleID: "", title: "") }
        while members.last?.bundleID.isEmpty == true { members.removeLast() }
        let idx = profile.displays.firstIndex { $0.uuid == u } ?? 0
        var pl = ScenePlacement(displayUUID: u, displayIndex: idx, spec: st.spec, members: members)
        let stacks = members.indices.map { j -> [WorkContext.Member] in
            guard j < st.slots.count, let top = st.slots[j] else { return [] }
            return (st.stacks[top] ?? []).compactMap { window($0) }.map(ContextResolver.member)
        }
        if stacks.contains(where: { !$0.isEmpty }) { pl.stacks = stacks }
        return pl
    }

    func renameScene(_ id: String, _ name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if let i = contexts.firstIndex(where: { $0.id == id }) {
            // 名字开头是 emoji 的，拆出来当图标
            if let f = t.first, f.unicodeScalars.first?.properties.isEmoji == true, f.unicodeScalars.first!.value > 0x2000 {
                contexts[i].emoji = String(f)
                let rest = t.dropFirst().trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { contexts[i].name = rest }
            } else { contexts[i].name = t }
            contexts[i].autoSolo = nil
        } else if let i = combos.firstIndex(where: { $0.id == id }) { combos[i].name = t }
        saveContexts()
    }

    func deleteSceneOrCombo(_ id: String) {
        if contexts.contains(where: { $0.id == id }) { contexts.removeAll { $0.id == id } } else { combos.removeAll { $0.id == id } }
        saveContexts()
    }

    /// 所有场景用到的窗口（切换器要截图）
    var sceneWindowIDs: [UInt32] { scenes.flatMap { sceneSlots($0).compactMap { $0.window?.id } } }

    // MARK: 场景 = 活的桌面

    /// 场景正摆在哪块（还接着的）屏上。拔掉的屏上「记着」的不算：不然点它的窗口会往一块不存在的屏上摆
    func showingOn(_ id: String) -> String? {
        showingScene.first { $0.value == id && profile.display(uuid: $0.key) != nil }?.key
    }

    /// 舞台模式下插拔了屏 / 换了显示器（AppDelegate 在屏幕真的变了时调用）。
    /// 场景归的是位置：某个位置又有屏了（插回同一台，或者换了一台：白天公司的屏、晚上家里的屏都是「扩展屏1」），
    /// 就把这个位置上次摆的场景摆回去；拔着的时候借住到别的屏上的场景回到自己的屏，借给它的屏回到它自己上次的场景
    func stageDisplaysChanged() {
        let prev = lastRoleMap ?? [:]
        let now = profile.roleMap
        lastRoleMap = now
        stage.displaysChanged()
        assignHomes()
        let arrived = now.filter { prev[$0.key] != $0.value }
        if stageActive, !prev.isEmpty, !arrived.isEmpty {
            var pairs: [(WorkContext, String)] = []
            var names: [String] = []
            for (r, u) in arrived.sorted(by: { DisplayProfile.roleOrder($0.key) < DisplayProfile.roleOrder($1.key) }) {
                guard let c = lastScene(of: r) else { continue }
                pairs.append((c, u))
                let d = profile.display(uuid: u)
                let swapped = prev[r] != nil || (knownDisplays[r].map { $0 != u } ?? false)
                names.append("\(DisplayProfile.roleName(r))\(swapped ? "（换成了 \(d?.name.prefix(12) ?? "")）" : "")摆回「\(c.name)」")
            }
            // 别的屏上正借住着刚回来那块屏的场景：回到它自己上次的场景
            for (r, u) in now where arrived[r] == nil {
                guard let sid = showingScene[u], let c = contexts.first(where: { $0.id == sid }), let h = c.home, arrived[h] != nil,
                      let own = lastScene(of: r) else { continue }
                pairs.append((own, u))
            }
            if !pairs.isEmpty, applyMany(pairs) > 0, !names.isEmpty { Toast.show("🖥 " + names.joined(separator: " · "), seconds: 2.2) }
        }
        for (r, u) in now { knownDisplays[r] = u }
        stageChanged()
    }

    /// 某个位置上次摆的（属于它自己的）场景；没记录就用这个位置最近用过的
    func lastScene(of r: String) -> WorkContext? {
        if let id = roleShowing[r], let c = contexts.first(where: { $0.id == id }) { return c }
        return scenes.filter { $0.home == r }.max { (sceneUsedAt[$0.id] ?? .distantPast) < (sceneUsedAt[$1.id] ?? .distantPast) }
            .flatMap { sceneUsedAt[$0.id] == nil ? nil : $0 }
    }

    /// 一次摆好几块屏（同一个窗口只上一块屏）
    @discardableResult
    func applyMany(_ pairs: [(WorkContext, String)]) -> Int {
        var used = Set<UInt32>()
        var list: [(display: String, spec: StageSpec, slots: [UInt32?], stacks: [UInt32: [UInt32]])] = []
        var shown: [(String, String)] = []
        for (c, u) in pairs {
            guard let p = placement(c, on: u, used: &used) else { continue }
            list.append(p)
            shown.append((c.id, u))
        }
        guard !list.isEmpty else { return 0 }
        stage.applySlots(list)
        if !stageActive { beginStage() } else { stageChanged() }
        for (sid, u) in shown { markShowing(sid, on: u) }
        refocusStage()
        return list.count
    }

    func markShowing(_ id: String, on u: String) {
        if let old = showingScene[u], old != id { dropIfBlank(old) }
        for (k, v) in showingScene where v == id && k != u { showingScene[k] = nil }
        showingScene[u] = id
        sceneUsedAt[id] = Date()
        // 只记「自己的」场景：借住进来的不算，屏插回来时这块屏要回到它自己的那个
        if let r = role(of: u), let c = contexts.first(where: { $0.id == id }), c.home == nil || c.home == r { roleShowing[r] = id }
    }

    /// 你在某块屏上调整了窗口（换窗口、换版式、拉比例、拖动换位）：自动存进这块屏正摆着的场景，不用另外「保存」
    func syncScenes() {
        var changed = false
        // 拖走的窗口又回到原来那块屏了：不算拖走
        for (id, u) in handMoved where stage.locate(id)?.display == u || stage.stackLocate(id)?.display == u { handMoved[id] = nil }
        for (u, id) in showingScene {
            guard let i = contexts.firstIndex(where: { $0.id == id }), let st = stage.stage(for: u), var pl = currentPlacement(u) else { continue }
            let old = contexts[i].plan?.first
            // 格子空着、但不是你把它请走的（窗口关了 / 最小化 / 隐藏 / 被另一块屏的场景借走了）：场景里继续记着它，
            // 不然退出一下微信、或者另一块屏摆了个也用微信的场景，这个场景就永远少了微信
            if let old {
                let was = sceneSlots(contexts[i])
                let empty = WorkContext.Member(bundleID: "", title: "")
                var ms = st.slots.indices.map { j in j < pl.members.count ? pl.members[j] : empty }
                let here = Set(st.slots.compactMap { $0 })
                for j in old.members.indices where j < was.count && !old.members[j].bundleID.isEmpty {
                    if let w = was[j].window, here.contains(w.id) { continue }   // 还在台上
                    guard keepInScene(was[j].window, member: old.members[j], display: u) else { continue }
                    // 原来那格空着就回原位；摆的时候已关的窗口不占格子（往前挤了），就接在后面
                    if j < ms.count, ms[j].bundleID.isEmpty { ms[j] = old.members[j] }
                    else if let k = ms.firstIndex(where: { $0.bundleID.isEmpty }) { ms[k] = old.members[j] }
                    else if ms.count < pl.layout.slots { ms.append(old.members[j]) }
                }
                while ms.last?.bundleID.isEmpty == true { ms.removeLast() }
                pl.members = ms
            }
            if old?.members.map(\.bundleID) != pl.members.map(\.bundleID) || old?.members.map(\.lastWindowID) != pl.members.map(\.lastWindowID)
                || old?.layout != pl.layout || abs((old?.ratio ?? 0) - pl.ratio) > 0.005 || old?.mirrored != pl.mirrored
                || old?.stacks?.map { $0.map(\.bundleID) } != pl.stacks?.map { $0.map(\.bundleID) } {
                contexts[i].plan = [pl]
                contexts[i].members = pl.members.filter { !$0.bundleID.isEmpty }
                // 你往里加了第二个窗口：是你自己搭的场景了，不再跟着 App 退出收掉（只换版式 / 比例不算）
                if contexts[i].members.count >= 2 { contexts[i].autoSolo = nil }
                // 空桌面里放进了第一个窗口：名字跟着它叫
                else if contexts[i].autoSolo == true, contexts[i].name == Self.blankName, let w = st.windows.first.flatMap({ window($0) }) {
                    contexts[i].name = soloName(w); contexts[i].emoji = "🪟"
                }
                changed = true
            }
        }
        if changed { saveContexts() }
        settleMovedAway()
    }

    /// 你把窗口亲手拖去了另一块屏之后的收尾：
    /// - 只装着它的自动场景没用了，删掉（不然在原来那块屏点它，窗口又被拉回来）
    /// - 原来那块屏整个空了：它正摆着的场景里拿掉这个窗口，然后摆回这块屏最近用过的场景（没有就留一张空桌面）
    func settleMovedAway() {
        guard !pendingLeft.isEmpty else { return }
        let list = pendingLeft
        pendingLeft = []
        var changed = false
        for (id, from) in list {
            if stage.locate(id)?.display == from || stage.stackLocate(id)?.display == from { continue }
            let now = stage.locate(id)?.display ?? stage.stackLocate(id)?.display
            func holds(_ c: WorkContext) -> Bool {
                c.members.contains { $0.lastWindowID == id } || sceneSlots(c).contains { $0.window?.id == id }
            }
            let solos = contexts.filter { c in
                c.autoSolo == true && c.members.count == 1 && holds(c) && (showingOn(c.id) == nil || showingOn(c.id) == from)
            }.map(\.id)
            var back: String?
            for sid in solos {
                back = back ?? soloReturn.removeValue(forKey: sid)
                for (k, v) in showingScene where v == sid { showingScene[k] = nil }
                sceneUsedAt[sid] = nil
            }
            if !solos.isEmpty { contexts.removeAll { solos.contains($0.id) }; changed = true }
            guard stageActive, stage.stage(for: from)?.windows.isEmpty != false else { continue }
            // 整块屏空了
            if let sid = showingScene[from], let i = contexts.firstIndex(where: { $0.id == sid }), var pl = contexts[i].plan?.first {
                let slots = sceneSlots(contexts[i])
                for j in pl.members.indices where pl.members[j].lastWindowID == id || (j < slots.count && slots[j].window?.id == id) {
                    pl.members[j] = WorkContext.Member(bundleID: "", title: "")
                }
                while pl.members.last?.bundleID.isEmpty == true { pl.members.removeLast() }
                contexts[i].plan = [pl]
                contexts[i].members = pl.members.filter { !$0.bundleID.isEmpty }
                changed = true
            }
            showingScene[from] = nil
            let cands = scenes.filter { c in
                guard belongs(c, to: from), showingOn(c.id) == nil else { return false }
                let ws = sceneSlots(c).compactMap(\.window).filter(\.axAvailable)
                // 不抢别的屏正摆着的窗口，也不把刚拖走的那个拉回来
                return !ws.isEmpty && !ws.contains { $0.id == id || stage.isOnStage($0.id) }
            }.sorted { (sceneUsedAt[$0.id] ?? .distantPast) > (sceneUsedAt[$1.id] ?? .distantPast) }
            let pick = cands.first { $0.id == back } ?? cands.first { sceneUsedAt[$0.id] != nil }
            if let pick, applyScene(pick, on: from) {
                stageLog.append(AppModel.clock.string(from: Date()) + " 窗口拖去了另一块屏，这块屏摆回「\(pick.name)」")
                // 键盘还是跟着你刚拖过去的那个窗口
                if let now { stage.focus(display: now) }
                system.focus(id)
            }
        }
        if changed { saveContexts(); stageChanged() }
    }

    // MARK: 空桌面

    static let blankName = "空桌面"

    /// 还空着的空桌面（你新建了、还没放窗口）
    func isBlank(_ id: String) -> Bool {
        contexts.first { $0.id == id }.map { $0.autoSolo == true && $0.members.isEmpty } ?? false
    }

    /// 离开一张还空着的空桌面：它没有内容，直接收掉
    func dropIfBlank(_ id: String) {
        guard isBlank(id) else { return }
        contexts.removeAll { $0.id == id }
        sceneUsedAt[id] = nil
    }

    /// 在这块屏上开一张空桌面：台上的窗口退到后台（原来的场景原样留着），马上弹出挑窗口的面板。
    /// 放进第一个窗口它就成了一个场景；什么都没放就切走，它自己消失
    func newDesk(on display: String? = nil) {
        guard Permissions.accessibility else { Toast.show("需要先授予辅助功能权限"); return }
        if !stageActive { enterStage() }
        guard stageActive, let u = display ?? stage.currentDisplay() ?? profile.main?.uuid, profile.display(uuid: u) != nil else { return }
        if let cur = showingScene[u], isBlank(cur), stage.stage(for: u)?.windows.isEmpty != false { onPickSlot(u, 0); return }
        syncScenes()
        var c = WorkContext(name: Self.blankName, emoji: "🫙", color: contexts.count, members: [])
        let idx = profile.displays.firstIndex { $0.uuid == u } ?? 0
        c.plan = [ScenePlacement(displayUUID: u, displayIndex: idx, spec: StageSpec(.focus), members: [])]
        c.home = role(of: u)
        c.autoSolo = true
        contexts.append(c)
        let prev = showingScene[u]
        if let prev { dropIfBlank(prev); soloReturn[c.id] = prev }
        // 先换成新场景再清屏：不然原来的场景会被当成「你把窗口都请走了」
        showingScene[u] = c.id
        sceneUsedAt[c.id] = Date()
        stage.clearAll(display: u)
        saveContexts()
        stageChanged()
        Toast.show("🫙 空桌面 · 挑一个窗口放进来，或者直接点 Dock 里的 App", seconds: 2)
        onPickSlot(u, 0)
    }

    /// 场景这一格原来的窗口现在不在台上：是你请走的（还开着、没最小化、也没上别的屏），还是只是暂时不在
    private func keepInScene(_ w: WindowInfo?, member m: WorkContext.Member, display u: String) -> Bool {
        // 没找到窗口：整个 App 退出了（重启电脑、退一下微信）→ 场景继续记着，下次开了还认得；
        // App 还开着、只是这个窗口关了 → 你不要它了，场景里也去掉（不然切场景的卡片里老挂着它）
        // （App 的窗口一个都不剩也算：正在退出的那一瞬间进程还在；微信这种关窗 = 收起来的也一样）
        guard let w else {
            return NSRunningApplication.runningApplications(withBundleIdentifier: m.bundleID).isEmpty || !system.windows().contains { $0.bundleID == m.bundleID }
        }
        if !w.axAvailable || w.isMinimized { return true }     // 在别的系统桌面 / 最小化了
        if w.pid > 0, NSRunningApplication(processIdentifier: w.pid)?.isHidden == true { return true }
        if handMoved[w.id] == u { return false }                     // 你亲手把它拖去了另一块屏
        if let loc = stage.locate(w.id) { return loc.display != u }   // 被另一块屏借走了；还在这块屏 = 你挪了格子
        return false
    }

    /// 一个窗口最该属于哪个场景：正摆着的优先，其次最近用过的，再其次场景里窗口少的（单独那个窗口的场景）
    func bestScene(containing w: WindowInfo) -> WorkContext? {
        let hits = scenes.filter { c in sceneSlots(c).contains { $0.window?.id == w.id } }
        let scored = hits.map { c in
            (c, (sceneShowing(c) != nil ? 1e12 : 0) + (sceneUsedAt[c.id]?.timeIntervalSince1970 ?? 0) - Double(c.plan?.first?.members.count ?? 0))
        }
        return scored.max { $0.1 < $1.1 }?.0
    }

    /// 你点了 Dock / ⌘Tab / 通知，切到一个没在台上的窗口：
    /// - 它在某个场景里 → 切到那个场景（在它正摆着的屏，或你正在用的屏）
    /// - 不在任何场景里 → 单独开一个新场景给它，然后问你要不要把它放进刚才那个场景的某一块
    /// 不再悄悄换掉你右边的窗口
    @discardableResult
    func handleActivation(_ w: WindowInfo) -> Bool {
        guard stageActive, stage.stageable(w) else { return false }
        let here = stage.currentDisplay() ?? profile.main?.uuid ?? ""
        let fromDock = clickedDock()
        // 这块屏是一张空桌面：你就是来拉窗口的，直接放进来（不跳去它原来的场景）
        if let sid = showingScene[here], isBlank(sid), stage.stage(for: here)?.windows.isEmpty != false {
            onPickSlot(here, -1)
            stage.present(w, on: here, slot: 0)
            stageChanged()
            syncScenes()
            system.focus(w.id)
            return true
        }
        if let sc = bestScene(containing: w) {
            // 场景正摆在某块屏上就去那块屏；不然回到它所属的那块屏（大屏的场景不会被挤到笔记本上）；那块屏没接才摆在你正在用的屏
            let u = showingOn(sc.id) ?? homeDisplay(sc) ?? here
            applyScene(sc, on: u)
            system.focus(w.id)
            return true
        }
        let prevStage = stage.stage(for: here)
        let prevScene = showingScene[here]
        var solo = WorkContext(name: soloName(w), emoji: "🪟", color: contexts.count, members: [ContextResolver.member(w)])
        let idx = profile.displays.firstIndex { $0.uuid == here } ?? 0
        solo.plan = [ScenePlacement(displayUUID: here, displayIndex: idx, spec: StageSpec(.focus), members: solo.members)]
        solo.autoSolo = true
        solo.home = role(of: here)
        contexts.append(solo)
        if let prevScene { soloReturn[solo.id] = prevScene }
        pruneAutoSolos(keeping: solo.id)
        saveContexts()
        guard applyScene(solo, on: here) else {
            contexts.removeAll { $0.id == solo.id }
            saveContexts()
            return false
        }
        system.focus(w.id)
        // 点 Dock 开的、又接着不止一块屏：Weft 不知道你想让它去哪块屏，卡片上让你挑
        let askScreen = fromDock && profile.displays.count > 1
        let had = prevStage.map { !$0.windows.isEmpty } ?? false
        if had || askScreen {
            onOfferPlacement(PlacementOffer(display: here, window: w, previous: prevStage ?? DisplayStage(spec: StageSpec(.focus), slots: []),
                                            previousScene: prevScene, soloScene: solo.id, askScreen: askScreen))
        }
        return true
    }

    /// 点 Dock 自动开的单独场景最多留 \(Self.maxAutoSolos) 个：再多就收掉最久没用、没摆着、你也没动过的
    static let maxAutoSolos = 6
    func pruneAutoSolos(keeping id: String) {
        let autos = contexts.enumerated().filter { $0.element.autoSolo == true && $0.element.id != id && !showingScene.values.contains($0.element.id) }
        let extra = autos.count - (Self.maxAutoSolos - 1)
        guard extra > 0 else { return }
        let old = autos.sorted { (sceneUsedAt[$0.element.id]?.timeIntervalSince1970 ?? Double($0.offset)) < (sceneUsedAt[$1.element.id]?.timeIntervalSince1970 ?? Double($1.offset)) }
            .prefix(extra).map(\.element.id)
        contexts.removeAll { old.contains($0.id) }
    }

    func soloName(_ w: WindowInfo) -> String {
        let same = windows.filter { $0.bundleID == w.bundleID }.count
        guard same > 1, !w.title.isEmpty, w.title != w.appName else { return w.appName }
        return "\(w.appName) · \(w.title.prefix(14))"
    }

    /// 选了「放进刚才那个场景的第 slot 块」（nil = 多加一格）：回到刚才的场景，这一块换成它；刚才自动开的单独场景删掉
    func acceptPlacement(_ o: PlacementOffer, slot: Int?, stack: Bool = false) {
        refresh(captureThumbs: false)
        guard let w = window(o.window.id) else { return }
        var slots = o.previous.slots
        var spec = o.previous.spec
        var stacks = o.previous.stacks
        if let slot, slots.indices.contains(slot) {
            // 叠上去：它在最上面，原来那个（连同它下面压着的）压到下面；换进去：只换最上面那个，下面压着的不动
            if let old = slots[slot] {
                var pile = stacks.removeValue(forKey: old) ?? []
                if stack { pile.append(old) }
                pile.removeAll { $0 == w.id }
                if !pile.isEmpty { stacks[w.id] = Array(pile.suffix(DisplayStage.maxStack - 1)) }
            }
            slots[slot] = w.id
        } else {
            let next: StageLayout = switch spec.layout {
            case .focus, .full: .split
            case .split: .mainStack
            case .mainStack, .triple, .quad: .quad
            }
            spec = StageSpec(next, mirrored: spec.mirrored)
            var s = slots.compactMap { $0 }.filter { $0 != w.id }
            s.append(w.id)
            slots = Array(s.prefix(next.slots)).map { Optional($0) }
        }
        contexts.removeAll { $0.id == o.soloScene }
        showingScene[o.display] = nil
        stage.applySlots([(o.display, spec, slots, stacks)])
        if let id = o.previousScene { showingScene[o.display] = id; sceneUsedAt[id] = Date() }
        stageChanged()
        system.focus(w.id)
        syncScenes()
        saveContexts()
    }

    /// 选了「以后随手」：刚才自动开的单独场景删掉、刚才的场景摆回来；这个 App 设成随手，窗口原地浮着
    func floatOffer(_ o: PlacementOffer) {
        contexts.removeAll { $0.id == o.soloScene }
        showingScene[o.display] = nil
        setFloating(o.window.bundleID, true, quiet: true)
        stage.applySlots([(o.display, o.previous.spec, o.previous.slots, o.previous.stacks)])
        if let id = o.previousScene { showingScene[o.display] = id; sceneUsedAt[id] = Date() }
        stageChanged()
        system.focus(o.window.id)
        syncScenes()
        saveContexts()
        Toast.show("🪶 \(o.window.appName) 以后是随手窗口：开了就浮在上面，不进场景、不再问 · 场景工作台左下角可以改回来", seconds: 2.6)
    }

    /// 卡片上点了另一块屏：这块屏摆回刚才的，新窗口的单独场景搬到那块屏
    func moveOffer(_ o: PlacementOffer, to u2: String) {
        guard u2 != o.display, let i = contexts.firstIndex(where: { $0.id == o.soloScene }) else { return }
        showingScene[o.display] = nil
        stage.applySlots([(o.display, o.previous.spec, o.previous.slots, o.previous.stacks)])
        if let id = o.previousScene { showingScene[o.display] = id; sceneUsedAt[id] = Date() }
        soloReturn[o.soloScene] = showingScene[u2]
        let idx = profile.displays.firstIndex { $0.uuid == u2 } ?? 0
        contexts[i].home = role(of: u2)
        contexts[i].plan = [ScenePlacement(displayUUID: u2, displayIndex: idx, spec: StageSpec(.focus), members: contexts[i].members)]
        applyScene(contexts[i], on: u2)
        stageChanged()
        system.focus(o.window.id)
        syncScenes()
        saveContexts()
    }

    /// 刚才那一下鼠标是不是点在 Dock 上（Dock 所在的那条屏幕边）
    func clickedDock() -> Bool {
        guard let c = lastClick, Date().timeIntervalSince(c.time) < 60,
              let s = NSScreen.screens.first(where: { $0.frame.contains(c.at) }) else { return false }
        let dock = UserDefaults(suiteName: "com.apple.dock")
        let side = dock?.string(forKey: "orientation") ?? "bottom"
        let tile = CGFloat(dock?.double(forKey: "tilesize") ?? 0)
        // 自动隐藏的 Dock 不占 visibleFrame：按图标大小估一条
        let hidden = (tile > 0 ? tile : 64) + 26
        let f = s.frame, v = s.visibleFrame
        switch side {
        case "left": return c.at.x <= f.minX + max(v.minX - f.minX, dock?.bool(forKey: "autohide") == true ? hidden : 0)
        case "right": return c.at.x >= f.maxX - max(f.maxX - v.maxX, dock?.bool(forKey: "autohide") == true ? hidden : 0)
        default: return c.at.y <= f.minY + max(v.minY - f.minY, dock?.bool(forKey: "autohide") == true ? hidden : 0)
        }
    }

    /// 格子里的窗口没了，要不要让上一个窗口补进来：
    /// 存好的场景里，这个 App 一个窗口都不剩了（退了）→ 不补，位置留给它，再开还回这里；自动开的单独场景也不补（整个场景马上会收掉）
    func sceneAllowsRefill(_ u: String, _ i: Int) -> Bool {
        guard let id = showingScene[u], let c = contexts.first(where: { $0.id == id }) else { return true }
        if c.autoSolo == true { return false }
        guard let ms = c.plan?.first?.members, ms.indices.contains(i), !ms[i].bundleID.isEmpty else { return true }
        let b = ms[i].bundleID
        return NSRunningApplication.runningApplications(withBundleIdentifier: b).contains { !$0.isTerminated } && system.windows().contains { $0.bundleID == b }
    }

    /// 自动开的单独场景（你没存过、也没往里加别的窗口）：它的窗口没了（App 退了 / 窗口关了）→ 场景跟着收掉，
    /// 正摆着它的那块屏回到之前的场景
    func reapAutoSolos() {
        let autos = contexts.filter { $0.autoSolo == true }
        guard !autos.isEmpty else { return }
        let live = system.windows()
        guard !live.isEmpty else { return }
        var gone: [WorkContext] = []
        for c in autos {
            if c.members.isEmpty { continue }   // 空桌面：切走时才收
            if let t = sceneUsedAt[c.id], Date().timeIntervalSince(t) < 4 { continue }   // 刚开的：窗口可能还没冒出来
            guard ContextResolver.resolve(c.members, in: live).isEmpty else { continue }
            let dead = c.members.allSatisfy { m in
                NSRunningApplication.runningApplications(withBundleIdentifier: m.bundleID).isEmpty || (m.lastWindowID.map { !system.exists($0) } ?? true)
            }
            if dead { gone.append(c) }
        }
        guard !gone.isEmpty else { return }
        for c in gone {
            let u = showingOn(c.id)
            contexts.removeAll { $0.id == c.id }
            sceneUsedAt[c.id] = nil
            let back = soloReturn.removeValue(forKey: c.id)
            guard stageActive, let u else { continue }
            showingScene[u] = nil
            if let back, let prev = contexts.first(where: { $0.id == back }), showingOn(prev.id) == nil, !resolved(prev).isEmpty {
                applyScene(prev, on: u)
            }
            stageLog.append(AppModel.clock.string(from: Date()) + " 自动场景「\(c.name)」的窗口没了，收掉")
        }
        saveContexts()
        stageChanged()
    }

    /// 选了「保持单独」：什么都不用做（新场景已经在了）
    func keepSolo(_ o: PlacementOffer) {
        Toast.show("🪟 「\(contexts.first { $0.id == o.soloScene }?.name ?? o.window.appName)」单独成了一个场景 · 场景切换器里随时切回来", seconds: 2)
    }
}


// MARK: - 场景工作台用的编辑

extension AppModel {
    /// 改一个场景；它正摆在某块屏上时，屏幕上立刻跟着变（所见即所得）
    func editScene(_ id: String, live: Bool = true, _ f: (inout WorkContext) -> Void) {
        guard let i = contexts.firstIndex(where: { $0.id == id }) else { return }
        f(&contexts[i])
        contexts[i].autoSolo = nil
        saveContexts()
        if live, stageActive, let u = showingOn(id) {
            applyScene(contexts[i], on: u)
        }
    }

    @discardableResult
    func createScene(on display: String? = nil) -> String {
        let n = scenes.count + 1
        var c = WorkContext(name: "场景 \(n)", emoji: "🎬", color: contexts.count, members: [])
        c.plan = [ScenePlacement(displayUUID: nil, displayIndex: 0, spec: StageSpec(.split), members: [])]
        c.home = (display ?? stage.currentDisplay() ?? profile.main?.uuid).flatMap { role(of: $0) }
        contexts.append(c)
        saveContexts()
        return c.id
    }

    /// 第 slot 格放这个窗口（nil = 空着）。同一个窗口在别的格子里就挪过来
    func setSceneSlot(_ id: String, _ slot: Int, _ w: WindowInfo?) {
        editScene(id) { c in
            guard var pl = c.plan?.first else { return }
            let empty = WorkContext.Member(bundleID: "", title: "")
            while pl.members.count <= slot { pl.members.append(empty) }
            var st = pl.stacks ?? []
            while st.count < pl.members.count { st.append([]) }
            if let w {
                for j in st.indices { st[j].removeAll { $0.lastWindowID == w.id } }
                for j in pl.members.indices where pl.members[j].lastWindowID == w.id { pl.members[j] = j == slot ? empty : (st[j].popLast() ?? empty) }
                pl.members[slot] = ContextResolver.member(w)
            } else {
                // 把最上面那个拿掉：下面压着的顶上来
                pl.members[slot] = st[slot].popLast() ?? empty
            }
            while pl.members.last?.bundleID.isEmpty == true, st.count < pl.members.count || st[pl.members.count - 1].isEmpty { pl.members.removeLast() }
            pl.stacks = st.contains { !$0.isEmpty } ? Array(st.prefix(pl.members.count)) : nil
            c.plan = [pl]
            c.members = pl.members.filter { !$0.bundleID.isEmpty }
        }
    }

    /// 把窗口叠到第 slot 格上：它在最上面，原来那个压到下面（一摞最多 \(DisplayStage.maxStack) 个）。格子空着就是普通地放进去
    func stackSceneSlot(_ id: String, _ slot: Int, _ w: WindowInfo) {
        editScene(id) { c in
            guard var pl = c.plan?.first else { return }
            let empty = WorkContext.Member(bundleID: "", title: "")
            while pl.members.count <= slot { pl.members.append(empty) }
            var st = pl.stacks ?? []
            while st.count < pl.members.count { st.append([]) }
            // 它原来在别处（别的格子 / 别的一摞里）：先拿出来，那一格下面压着的顶上来
            for j in st.indices { st[j].removeAll { $0.lastWindowID == w.id } }
            for j in pl.members.indices where j != slot && pl.members[j].lastWindowID == w.id {
                pl.members[j] = st[j].popLast() ?? empty
            }
            let old = pl.members[slot]
            if !old.bundleID.isEmpty, old.lastWindowID != w.id { st[slot].append(old) }
            st[slot] = Array(st[slot].suffix(DisplayStage.maxStack - 1))
            pl.members[slot] = ContextResolver.member(w)
            pl.stacks = st.contains { !$0.isEmpty } ? st : nil
            c.plan = [pl]
            c.members = pl.members.filter { !$0.bundleID.isEmpty }
        }
    }

    /// 把第 slot 格下面压着的第 k 个（从最底下数）拿掉
    func unstackSceneSlot(_ id: String, _ slot: Int, _ k: Int) {
        editScene(id) { c in
            guard var pl = c.plan?.first, var st = pl.stacks, st.indices.contains(slot), st[slot].indices.contains(k) else { return }
            st[slot].remove(at: k)
            pl.stacks = st.contains { !$0.isEmpty } ? st : nil
            c.plan = [pl]
        }
    }

    /// 场景第 slot 格下面压着的窗口（从最底下开始；找不到的窗口 = 已关闭）
    func sceneStack(_ c: WorkContext, _ slot: Int) -> [(member: WorkContext.Member, window: WindowInfo?)] {
        guard let st = c.plan?.first?.stacks, st.indices.contains(slot) else { return [] }
        return st[slot].map { m in (m, ContextResolver.resolve([m], in: windows).first) }
    }

    func setSceneLayout(_ id: String, _ layout: StageLayout) {
        editScene(id) { c in
            guard var pl = c.plan?.first, pl.layout != layout else { return }
            pl.layout = layout
            pl.ratio = StageSpec.defaultRatio(layout)
            c.plan = [pl]
        }
    }

    func cycleSceneRatio(_ id: String) {
        editScene(id) { c in
            guard var pl = c.plan?.first else { return }
            let ch = pl.spec.ratioChoices
            guard !ch.isEmpty else { return }
            let i = ch.firstIndex { abs($0 - pl.ratio) < 0.01 } ?? -1
            pl.ratio = ch[(i + 1) % ch.count]
            c.plan = [pl]
        }
    }

    func setSceneName(_ id: String, name: String, emoji: String) {
        editScene(id, live: false) { c in
            let n = name.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { c.name = n }
            let e = emoji.trimmingCharacters(in: .whitespaces)
            if !e.isEmpty { c.emoji = String(e.prefix(2)) }
        }
    }
}

/// 「要不要放进刚才那个场景」的提议
struct PlacementOffer {
    var display: String
    var window: WindowInfo
    var previous: DisplayStage
    var previousScene: String?
    var soloScene: String
    /// 点 Dock 开的：卡片上多一排屏幕让你挑
    var askScreen = false
}

// MARK: - 绑定：切一块屏的场景，别的屏跟着切
//
// 场景只管一块屏；绑定把不同屏的几个场景连成一组（SceneCombo.linked）。
// 你在任何一块屏上切到其中一个（⌃←→、四指滑、切换器、工作台），组里别的场景同时摆到它们自己的屏上。
// 一个场景只在一个绑定组里；点 Dock 自动切过去的不联动（那是你在找一个窗口，不是在换整套工作台）。

extension AppModel {
    /// 场景所在的绑定组
    func linkGroup(of id: String) -> SceneCombo? { combos.first { $0.isLinked && $0.parts.contains { $0.sceneID == id } } }

    /// 这个场景绑着的另一块屏上的场景（按屏的位置）
    func linkedPartner(of id: String, role r: String) -> WorkContext? {
        guard let g = linkGroup(of: id) else { return nil }
        return g.parts.lazy.compactMap { p in self.contexts.first { $0.id == p.sceneID } }.first { $0.id != id && $0.home == r }
    }

    /// 切场景（会带上绑定的场景）。返回摆出来的块数
    @discardableResult
    func switchScene(_ c: WorkContext, on display: String?) -> Bool {
        guard let g = linkGroup(of: c.id) else { return applyScene(c, on: display) }
        refresh(captureThumbs: false)
        guard let u = display ?? homeDisplay(c) ?? stage.currentDisplay() ?? profile.main?.uuid else { return false }
        var pairs: [(WorkContext, String)] = [(c, u)]
        var taken: Set<String> = [u]
        for p in g.parts where p.sceneID != c.id {
            // 跟着切的场景回它自己的屏；那块屏没接就不摆（不挤到别的屏上）
            guard let o = contexts.first(where: { $0.id == p.sceneID }), let v = homeDisplay(o), !taken.contains(v) else { continue }
            taken.insert(v)
            pairs.append((o, v))
        }
        let n = applyMany(pairs)
        guard n > 0 else { return applyScene(c, on: u) }
        let others = pairs.dropFirst().map(\.0.name)
        Toast.show("\(c.emoji) \(c.name)" + (others.isEmpty ? "" : " · 🔗 " + others.joined(separator: "、")), seconds: 1.6)
        return true
    }

    /// 绑定 / 换绑 / 解绑：让 a 和另一块屏（role）上的 b 一起切；b = nil 就是解掉 a 在那块屏上的绑定
    func bind(_ aID: String, role r: String, to bID: String?) {
        guard let a = contexts.first(where: { $0.id == aID }) else { return }
        // 先把 a 在那块屏上的旧搭档拿出来
        if let old = linkedPartner(of: aID, role: r) { unlink(old.id, keepToast: true) }
        guard let bID, let b = contexts.first(where: { $0.id == bID }), bID != aID else {
            saveContexts()
            Toast.show("🔗 「\(a.name)」不再带着\(DisplayProfile.roleName(r))一起切", seconds: 1.6)
            return
        }
        // b 原来在别的组里：拿出来（一个场景只在一个组里）
        if let gb = linkGroup(of: bID), gb.id != linkGroup(of: aID)?.id { unlink(bID, keepToast: true) }
        let part = { (c: WorkContext) -> SceneCombo.Part in
            let u = self.homeDisplay(c)
            return .init(sceneID: c.id, displayUUID: u, displayIndex: self.profile.displays.firstIndex { $0.uuid == u } ?? 0)
        }
        if let i = combos.firstIndex(where: { $0.isLinked && $0.parts.contains { $0.sceneID == aID } }) {
            combos[i].parts.append(part(b))
            combos[i].name = combos[i].parts.compactMap { p in contexts.first { $0.id == p.sceneID }?.name }.joined(separator: " + ")
        } else {
            combos.append(SceneCombo(name: "\(a.name) + \(b.name)", emoji: "🔗", parts: [part(a), part(b)], linked: true))
        }
        saveContexts()
        Toast.show("🔗 绑好了：切到「\(a.name)」时\(DisplayProfile.roleName(r))跟着切到「\(b.name)」，反过来也一样", seconds: 2.4)
    }

    /// 把一个场景从它的绑定组里拿出来（组里剩不到两个就整组解散）
    func unlink(_ id: String, keepToast: Bool = false) {
        guard let i = combos.firstIndex(where: { $0.isLinked && $0.parts.contains { $0.sceneID == id } }) else { return }
        combos[i].parts.removeAll { $0.sceneID == id }
        if combos[i].parts.count < 2 { combos.remove(at: i) }
        else { combos[i].name = combos[i].parts.compactMap { p in contexts.first { $0.id == p.sceneID }?.name }.joined(separator: " + ") }
        if !keepToast { saveContexts(); Toast.show("🔗 已解绑", seconds: 1.2) }
    }

    /// 老组合打开 / 关掉联动（打开时组里的场景先从别的绑定组里拿出来）
    func setLinked(_ comboID: String, _ on: Bool) {
        guard let i = combos.firstIndex(where: { $0.id == comboID }) else { return }
        if on {
            let ids = Set(combos[i].parts.map(\.sceneID))
            for j in combos.indices where j != i && combos[j].isLinked { combos[j].parts.removeAll { ids.contains($0.sceneID) } }
            combos.removeAll { $0.id != comboID && $0.parts.count < 2 }
        }
        if let k = combos.firstIndex(where: { $0.id == comboID }) { combos[k].linked = on ? true : nil }
        saveContexts()
        Toast.show(on ? "🔗 联动打开：切到组合里任何一个场景，别的屏跟着切" : "组合不再联动", seconds: 1.8)
    }

    /// 能和这个场景绑在一起的：别的屏上的场景
    func bindCandidates(for c: WorkContext, role r: String) -> [WorkContext] { scenes.filter { $0.id != c.id && $0.home == r } }

    /// 除了这个场景自己的屏，还有哪几块屏（接着的 + 有场景归它的）
    func otherRoles(than c: WorkContext) -> [String] {
        // 只列现在接着的屏（没接的屏上的场景切了也摆不出来）
        let roles = Set(profile.roleMap.keys)
        return roles.filter { $0 != c.home }.sorted { DisplayProfile.roleOrder($0) < DisplayProfile.roleOrder($1) }
    }
}

// MARK: - 随手窗口
//
// 有的窗口适合固定在场景里（编辑器、Claude），有的随开随关（访达、预览、系统设置）。
// 随手 App 的窗口不进场景、不占格子、切场景时不藏、不弹「放进哪一块」，原样浮在上面；关掉就没了，不留痕迹。

extension AppModel {
    func isFloating(_ bundleID: String) -> Bool { settings.floatingApps.contains(bundleID) }

    func setFloating(_ bundleID: String, _ on: Bool, quiet: Bool = false) {
        guard !bundleID.isEmpty, isFloating(bundleID) != on else { return }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
            ?? bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        if on {
            settings.floatingApps.append(bundleID)
            saveSettings()
            // 现在台上 / 藏着的这个 App 的窗口：放出来，原地浮着
            for w in windows where w.bundleID == bundleID {
                if stage.isOnStage(w.id) { stage.letGo(w.id) }
                if stash.isStashed(w.id) { _ = stash.unstash(w.id, focus: false) }
            }
            // 场景里去掉它；只剩它的场景删掉
            var removed = 0
            for i in contexts.indices where contexts[i].plan?.count == 1 {
                guard contexts[i].plan![0].members.contains(where: { $0.bundleID == bundleID }) else { continue }
                contexts[i].plan![0].members.removeAll { $0.bundleID == bundleID }
                contexts[i].members.removeAll { $0.bundleID == bundleID }
                removed += 1
            }
            let empty = contexts.filter { $0.plan?.count == 1 && $0.plan![0].members.allSatisfy(\.bundleID.isEmpty) }.map(\.id)
            contexts.removeAll { empty.contains($0.id) }
            saveContexts()
            if stageActive { stageChanged() }
            if !quiet { Toast.show("🪶 \(name) 变成随手窗口：不进场景、切场景不藏" + (removed > 0 ? " · 从 \(removed) 个场景里拿掉了" : "") + (empty.isEmpty ? "" : "，删了 \(empty.count) 个空场景"), seconds: 2.6) }
        } else {
            settings.floatingApps.removeAll { $0 == bundleID }
            saveSettings()
            if !quiet { Toast.show("\(name) 不再是随手窗口：又能放进场景了", seconds: 1.6) }
        }
    }
}
