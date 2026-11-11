import AppKit
import CoreGraphics
import Foundation

/// 「事情」：一组为了同一件事打开的窗口，可跨 App、跨屏幕。
public struct WorkContext: Codable, Identifiable, Equatable {
    public struct Member: Codable, Equatable {
        public var bundleID: String
        public var title: String
        public var lastWindowID: UInt32?
        public init(bundleID: String, title: String, lastWindowID: UInt32? = nil) {
            self.bundleID = bundleID; self.title = title; self.lastWindowID = lastWindowID
        }
    }

    public var id: String
    public var name: String
    public var emoji: String
    public var color: Int
    public var members: [Member]
    /// 显示器指纹 → 该事情的布局
    public var layouts: [String: [SavedWindow]] = [:]
    /// 场景：每块屏用什么版式、每个格子放谁（AI 整理桌面给出的；有它时「进入」= 按它摆上舞台）
    public var plan: [ScenePlacement]?
    /// 点 Dock 时自动开的单独场景（你还没动过它）。这种场景太多时，最久没用的会被自动收掉
    public var autoSolo: Bool?
    /// 这个场景属于哪块屏：laptop / ext1 / ext2…（见 DisplayProfile.role）。nil = 还没归屏（老数据），每块屏都列出来
    public var home: String?
    /// 收进回收站的时间（只在 ContextDB.trash 里有值）
    public var removedAt: Date?

    public init(id: String = UUID().uuidString, name: String, emoji: String, color: Int, members: [Member]) {
        self.id = id; self.name = name; self.emoji = emoji; self.color = color; self.members = members
    }
}

public struct ScenePlacement: Codable, Equatable {
    public var displayUUID: String?
    /// 屏幕不认识时（换了显示器）按序号兜底
    public var displayIndex: Int
    public var layout: StageLayout
    public var ratio: Double
    public var mirrored: Bool
    /// 按格子顺序
    public var members: [WorkContext.Member]
    /// AI 给这块屏单独起的名字（拆成独立场景时用）
    public var name: String?
    /// 叠放：第 i 格最上面那个窗口下面还压着谁（从最底下开始）。没有叠放的场景为 nil
    public var stacks: [[WorkContext.Member]]?

    public init(displayUUID: String?, displayIndex: Int, spec: StageSpec, members: [WorkContext.Member], name: String? = nil) {
        self.displayUUID = displayUUID; self.displayIndex = displayIndex
        self.layout = spec.layout; self.ratio = spec.ratio; self.mirrored = spec.mirrored; self.members = members
        self.name = name
    }

    public var spec: StageSpec { StageSpec(layout, ratio: ratio, mirrored: mirrored) }
}

/// 场景组合：几个场景同时摆在几块屏上（「笔记本放回消息 + 大屏放写代码」）。
/// 记的是「上次放在哪块屏」，那块屏不在时按顺序放到别的屏——场景本身不绑屏幕
public struct SceneCombo: Codable, Identifiable, Equatable {
    public struct Part: Codable, Equatable {
        public var sceneID: String
        public var displayUUID: String?
        public var displayIndex: Int
        public init(sceneID: String, displayUUID: String?, displayIndex: Int) {
            self.sceneID = sceneID; self.displayUUID = displayUUID; self.displayIndex = displayIndex
        }
    }
    public var id: String
    public var name: String
    public var emoji: String
    public var parts: [Part]
    /// 绑定（联动）：切到其中任何一个场景时，别的屏跟着切到组合里对应的那个。nil / false = 只是个能一键摆出来的组合
    public var linked: Bool?
    public init(id: String = UUID().uuidString, name: String, emoji: String, parts: [Part], linked: Bool? = nil) {
        self.id = id; self.name = name; self.emoji = emoji; self.parts = parts; self.linked = linked
    }
    public var isLinked: Bool { linked == true }
}

/// 场景 = 一块屏上的一个版式 + 几个窗口，可以摆到任意一块屏上。
public enum SceneBook {
    /// 一个场景只管一块屏。旧的 / AI 给的「一个场景跨两块屏」拆成两个独立场景 + 一个组合
    public static func split(_ contexts: [WorkContext]) -> (contexts: [WorkContext], combos: [SceneCombo]) {
        var out: [WorkContext] = []
        var combos: [SceneCombo] = []
        for c in contexts {
            guard let plan = c.plan, plan.count > 1 else { out.append(c); continue }
            let parts = plan.sorted { $0.displayIndex < $1.displayIndex }
            var comboParts: [SceneCombo.Part] = []
            var names = Set(out.map(\.name))
            for (k, pl) in parts.enumerated() {
                var s: WorkContext
                if k == 0 {
                    s = c
                    if let n = pl.name, !n.isEmpty, !names.contains("\(c.name) · \(n)") { s.name = "\(c.name) · \(n)" }
                } else {
                    var name = pl.name.map { "\(c.name) · \($0)" } ?? "\(c.name) · \(appNames(pl.members))"
                    if names.contains(name) { name = "\(c.name) · \(k + 1)" }
                    s = WorkContext(name: name, emoji: c.emoji, color: c.color, members: pl.members)
                }
                s.members = pl.members
                s.plan = [pl]
                names.insert(s.name)
                out.append(s)
                comboParts.append(.init(sceneID: s.id, displayUUID: pl.displayUUID, displayIndex: pl.displayIndex))
            }
            combos.append(SceneCombo(name: c.name, emoji: c.emoji, parts: comboParts))
        }
        return (out, combos)
    }

    /// 「钉钉 + Telegram」：拆出来的场景没有名字时，用里面的 App 起名
    static func appNames(_ ms: [WorkContext.Member]) -> String {
        var seen = Set<String>()
        let names = ms.compactMap { m -> String? in
            // 正在运行的 App 用系统显示的名字（钉钉、企业微信），不然退回到 App 文件名
            if let n = NSRunningApplication.runningApplications(withBundleIdentifier: m.bundleID).first?.localizedName { return n }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: m.bundleID) else { return m.bundleID.split(separator: ".").last.map(String.init) }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }.filter { seen.insert($0).inserted }
        return names.isEmpty ? "副屏" : names.prefix(2).joined(separator: " + ")
    }

    /// 组合里每个场景放哪块屏：上次那块屏在就放回去，不在就按顺序放到还空着的屏；屏幕不够的部分不摆
    public static func assign(_ combo: SceneCombo, to profile: DisplayProfile) -> [(sceneID: String, display: String)] {
        var used = Set<String>()
        var out: [(String, String)] = []
        var rest: [SceneCombo.Part] = []
        for p in combo.parts {
            if let u = p.displayUUID, profile.display(uuid: u) != nil, !used.contains(u) { used.insert(u); out.append((p.sceneID, u)) } else { rest.append(p) }
        }
        let free = profile.displays.filter { !used.contains($0.uuid) }
        for (p, d) in zip(rest.sorted { $0.displayIndex < $1.displayIndex }, free) { out.append((p.sceneID, d.uuid)) }
        return out
    }
}

public struct ContextDB: Codable {
    public var contexts: [WorkContext] = []
    public var combos: [SceneCombo]?
    public var pinned: [WorkContext.Member] = []
    /// 老数据里「自动开的单独场景」已经补过标记了
    public var soloMigrated: Bool?
    /// 最近收掉的场景（自动收掉的、你删的）：7 天内能在场景工作台里找回来
    public var trash: [WorkContext]?
    /// 舞台模式开着时退出 / 重启的：下次启动自动恢复舞台，每块屏摆回上次的场景
    public var stageWasOn: Bool?
    /// 每块屏（位置：laptop / ext1…）上次摆的场景
    public var lastShowing: [String: String]?
    public init() {}
}

public enum ContextResolver {
    /// 找出事情在当前 live 窗口里对应的窗口
    public static func resolve(_ members: [WorkContext.Member], in live: [WindowInfo]) -> [WindowInfo] {
        var used = Set<UInt32>()
        var out: [WindowInfo] = []
        for m in members {
            if let id = m.lastWindowID, let w = live.first(where: { $0.id == id && $0.bundleID == m.bundleID }), !used.contains(id) {
                used.insert(id); out.append(w); continue
            }
            let cands = live.filter { $0.bundleID == m.bundleID && !used.contains($0.id) }
            if let best = cands.max(by: { WindowMatcher.similarity($0.title, m.title) < WindowMatcher.similarity($1.title, m.title) }),
               WindowMatcher.similarity(best.title, m.title) > 0.6 || cands.count == 1 && m.title.isEmpty {
                used.insert(best.id); out.append(best)
            }
        }
        return out
    }

    /// 所有场景一起认窗口。groups = 每个场景一组成员（排好优先级：正摆着的、最近用过的在前），返回每组每个成员对应的窗口。
    ///
    /// 只靠「上次的窗口编号 + 标题像不像」认不出两种情况：电脑重启（窗口编号全换了）和标题一直在变的 App
    /// （Claude、Codex、ChatGPT 的窗口标题就是当前对话名，浏览器是当前标签页）。以前认不出就当成窗口没了，
    /// 场景里的这一格被删掉、点 Dock 又给它另开一个场景。所以分两轮：
    /// 1. 认得准的：窗口编号还对得上，或者标题很像（>0.6）。一个窗口可以同时在几个场景里
    /// 2. 还没认出来的成员，从同一个 App 里「谁都没认走」的窗口里领一个（最近用的场景先领，几个场景尽量分到不同的窗口）；
    ///    这个 App 只开着一个窗口时，它就是那个窗口，别的场景认走了也一样领（Claude 这类单窗口 App 放在好几个场景里很正常）
    /// 返回值的 strong[组][成员] = 是不是第 1 轮认出来的
    public static func resolveAll(_ groups: [[WorkContext.Member]], in live: [WindowInfo]) -> (windows: [[UInt32?]], strong: [[Bool]]) {
        var out = groups.map { [UInt32?](repeating: nil, count: $0.count) }
        var strong = groups.map { [Bool](repeating: false, count: $0.count) }
        var claimed = Set<UInt32>()
        var usedIn = groups.map { _ in Set<UInt32>() }
        for (g, ms) in groups.enumerated() {
            for (k, m) in ms.enumerated() where !m.bundleID.isEmpty {
                if let id = m.lastWindowID, live.contains(where: { $0.id == id && $0.bundleID == m.bundleID }), !usedIn[g].contains(id) {
                    out[g][k] = id; strong[g][k] = true; usedIn[g].insert(id); claimed.insert(id)
                }
            }
            for (k, m) in ms.enumerated() where !m.bundleID.isEmpty && out[g][k] == nil && !m.title.isEmpty {
                let cands = live.filter { $0.bundleID == m.bundleID && !usedIn[g].contains($0.id) }
                if let best = cands.max(by: { WindowMatcher.similarity($0.title, m.title) < WindowMatcher.similarity($1.title, m.title) }),
                   WindowMatcher.similarity(best.title, m.title) > 0.6 {
                    out[g][k] = best.id; strong[g][k] = true; usedIn[g].insert(best.id); claimed.insert(best.id)
                }
            }
        }
        var handed: [UInt32: Int] = [:]
        for (g, ms) in groups.enumerated() {
            for (k, m) in ms.enumerated() where !m.bundleID.isEmpty && out[g][k] == nil {
                let mine = live.filter { $0.bundleID == m.bundleID && !usedIn[g].contains($0.id) }
                let all = live.filter { $0.bundleID == m.bundleID }
                let pool = all.count == 1 ? mine : mine.filter { !claimed.contains($0.id) }
                guard let w = pool.min(by: { a, b in
                    let ha = handed[a.id, default: 0], hb = handed[b.id, default: 0]
                    if ha != hb { return ha < hb }
                    return WindowMatcher.similarity(a.title, m.title) > WindowMatcher.similarity(b.title, m.title)
                }) else { continue }
                out[g][k] = w.id; usedIn[g].insert(w.id); handed[w.id, default: 0] += 1
            }
        }
        return (out, strong)
    }

    public static func member(_ w: WindowInfo) -> WorkContext.Member {
        WorkContext.Member(bundleID: w.bundleID, title: HabitTracker.normalize(w.title), lastWindowID: w.id)
    }
}

/// 停靠：把窗口挪到屏幕外（不用最小化，进出都是瞬间完成），缩略图留在侧边栏。
public struct StashEntry: Codable, Equatable {
    public var windowID: UInt32
    public var bundleID: String
    public var title: String
    public var originalFrame: CGRect
    /// 舞台模式藏到后台的（不是手动停靠）
    public var byStage: Bool?
    /// 挪不出屏幕的窗口（有的 App 会自己把窗口拉回屏幕内）改用最小化藏起来
    public var viaMinimize: Bool?
    public var isManual: Bool { byStage != true }
}

public final class StashManager {
    public private(set) var entries: [StashEntry]
    private let store: Store
    private let actions: WindowActions

    public init(actions: WindowActions, store: Store = .shared) {
        self.actions = actions
        self.store = store
        self.entries = store.load([StashEntry].self, "stash.json") ?? []
    }

    private func persist() { store.save(entries, "stash.json") }

    /// 藏窗口的位置：贴着「自己那块屏幕」的某个角、而且外面没有别的屏幕，只露 1px。
    /// 贴着自己的屏幕，macOS 不会把它拽到别的屏幕上；叫回来时也回到原来那块屏
    public static func parkingSpot(for size: CGSize, home: DisplayInfo?, in p: DisplayProfile) -> CGPoint {
        let ds = p.displays
        func free(_ r: CGRect) -> Bool { !ds.contains { $0.frame.intersects(r) } }
        if let d = home?.frame {
            let candidates = [
                CGPoint(x: d.maxX - 1, y: d.maxY - 1),                          // 右下
                CGPoint(x: d.minX - size.width + 1, y: d.maxY - 1),             // 左下
                CGPoint(x: d.maxX - 1, y: d.minY - size.height + 1),            // 右上
                CGPoint(x: d.minX - size.width + 1, y: d.minY - size.height + 1), // 左上
            ]
            for c in candidates {
                let r = CGRect(origin: c, size: size).insetBy(dx: 1, dy: 1)
                let outside = r.offsetBy(dx: c.x >= d.maxX - 1 ? 1 : -1, dy: c.y >= d.maxY - 1 ? 1 : -1)
                if free(outside) { return c }
            }
        }
        let maxX = ds.map(\.frame.maxX).max() ?? 3000
        let maxY = ds.map(\.frame.maxY).max() ?? 2000
        return CGPoint(x: maxX - 1, y: maxY - 1)
    }

    /// 窗口是不是真的在屏幕外（最多露出一条边）
    public func isParked(_ w: WindowInfo) -> Bool {
        if w.isMinimized { return true }
        let p = actions.profile()
        return !p.displays.contains { d in
            let i = d.frame.intersection(w.frame)
            return !i.isNull && i.width > 40 && i.height > 40
        }
    }

    private var reparkTries: [UInt32: Int] = [:]

    /// 重新藏好；连续藏不住（App 不让窗口离开屏幕）就最小化
    @discardableResult
    public func repark(_ w: WindowInfo) -> Bool {
        guard let i = entries.firstIndex(where: { $0.windowID == w.id }) else { return false }
        let n = reparkTries[w.id, default: 0] + 1
        reparkTries[w.id] = n
        if n >= 3 {
            actions.setMinimized(w.id, true)
            entries[i].viaMinimize = true
            persist()
            return true
        }
        let p = actions.profile()
        let home = p.display(containing: entries[i].originalFrame.center) ?? p.main
        actions.setFrame(w.id, CGRect(origin: StashManager.parkingSpot(for: w.frame.size, home: home, in: p), size: w.frame.size))
        return true
    }

    /// 检查所有后台窗口是否真的藏好了（被 App 拉回屏幕的重新藏），返回处理了几个
    @discardableResult
    public func enforce(live: [WindowInfo], except: Set<UInt32> = []) -> Int {
        var n = 0
        for w in live where isStashed(w.id) && !except.contains(w.id) && !isParked(w) {
            repark(w); n += 1
        }
        for id in reparkTries.keys where !isStashed(id) { reparkTries[id] = nil }
        return n
    }

    public func isStashed(_ id: UInt32) -> Bool { entries.contains { $0.windowID == id } }

    public func stash(_ w: WindowInfo, original: CGRect? = nil, byStage: Bool = false, near display: String? = nil) {
        guard w.axAvailable else { return }
        if let i = entries.firstIndex(where: { $0.windowID == w.id }) {
            // 已经在后台：手动停靠会把「舞台藏起」升级为「手动停靠」
            if !byStage { entries[i].byStage = nil; persist() }
            // 记录说藏着，窗口却回到了屏幕上（App 自己拉回来的）：再藏一次
            if !isParked(w) { repark(w) }
            return
        }
        let p = actions.profile()
        let o = original ?? w.frame
        entries.append(StashEntry(windowID: w.id, bundleID: w.bundleID, title: w.title,
                                  originalFrame: o, byStage: byStage ? true : nil))
        let home = display.flatMap { p.display(uuid: $0) } ?? p.display(containing: o.center) ?? p.main
        actions.setFrame(w.id, CGRect(origin: StashManager.parkingSpot(for: w.frame.size, home: home, in: p), size: w.frame.size))
        persist()
    }

    /// 从后台取出但不移动（调用方马上会把它放到新位置）
    @discardableResult
    public func release(_ id: UInt32) -> StashEntry? {
        guard let i = entries.firstIndex(where: { $0.windowID == id }) else { return nil }
        let e = entries.remove(at: i)
        reparkTries[id] = nil
        if e.viaMinimize == true { actions.setMinimized(id, false) }
        persist()
        return e
    }

    public func entry(_ id: UInt32) -> StashEntry? { entries.first { $0.windowID == id } }

    @discardableResult
    public func unstash(_ id: UInt32, focus: Bool = true) -> Bool {
        guard let i = entries.firstIndex(where: { $0.windowID == id }) else { return false }
        let e = entries.remove(at: i)
        if e.viaMinimize == true { actions.setMinimized(id, false) }
        let p = actions.profile()
        var f = e.originalFrame
        defer { persist() }
        if let d = p.display(containing: f.center) { f = f.clamped(to: d.visible) } else if let m = p.main { f = f.clamped(to: m.visible) }
        guard actions.setFrame(id, f) else { entries.append(e); return false }   // 放不回去：记录留着
        if focus { actions.focus(id) }
        return true
    }

    /// 退出 / 崩溃恢复时全部放回
    public func restoreAll() {
        // 只清掉放回成功的和真的关掉的；看不到（锁屏）的留着，下次启动再放回
        guard actions.canObserve else { return }
        let live = Set(actions.windows().map(\.id))
        for e in entries where live.contains(e.windowID) { _ = unstash(e.windowID, focus: false) }
        entries.removeAll { !actions.exists($0.windowID) }
        persist()
    }

    /// 窗口已经关掉的条目清理掉
    public func prune(live: [WindowInfo]) {
        guard actions.canObserve else { return }
        let ids = Set(live.map(\.id))
        let before = entries.count
        // 列表里没有不一定是关了（AX 暂时拿不到）：再问一次窗口服务器
        entries.removeAll { !ids.contains($0.windowID) && !actions.exists($0.windowID) }
        if entries.count != before { persist() }
    }
}
