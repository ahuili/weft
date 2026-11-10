import AppKit
import CoreGraphics
import Foundation

// MARK: - 舞台模式
//
// 不管开了多少窗口，每块屏幕上只「上台」你现在要用的 1~3 个，按版式排好；
// 其余窗口都退到「后台」（挪到屏幕外，进出都是瞬间完成，状态完整保留）。
// 你用任何方式（⌥Tab、侧边栏、⌘Tab、点 Dock）切到一个窗口，它就上台，替换掉当前位置上的那个。

public enum StageLayout: String, Codable, CaseIterable {
    case focus      // 单窗：居中舒展，两边留白
    case full       // 单窗：铺满
    case split      // 左右两栏
    case mainStack  // 一主两辅：左边主窗口，右边上下两个
    case triple     // 三栏：中间主窗口
    case quad       // 四宫格

    public var slots: Int {
        switch self {
        case .focus, .full: return 1
        case .split: return 2
        case .mainStack, .triple: return 3
        case .quad: return 4
        }
    }

    public var title: String {
        switch self {
        case .focus: return "专注"
        case .full: return "铺满"
        case .split: return "左右"
        case .mainStack: return "一主两辅"
        case .triple: return "三栏"
        case .quad: return "四宫格"
        }
    }
}

public struct StageSpec: Codable, Equatable {
    public var layout: StageLayout
    /// split / mainStack：主窗口占的宽度比例；triple：中间那栏的宽度比例
    public var ratio: Double
    /// 主窗口放右边
    public var mirrored: Bool

    public init(_ layout: StageLayout, ratio: Double? = nil, mirrored: Bool = false) {
        self.layout = layout
        self.ratio = ratio ?? StageSpec.defaultRatio(layout)
        self.mirrored = mirrored
    }

    public static func defaultRatio(_ l: StageLayout) -> Double {
        switch l {
        case .split: return 0.5
        case .mainStack: return 0.62
        case .triple: return 0.4
        case .quad: return 0.5
        case .focus, .full: return 1
        }
    }

    /// 可选比例（循环切换用）
    public var ratioChoices: [Double] {
        switch layout {
        case .split: return [0.5, 0.6, 0.7, 0.4, 0.3]
        case .mainStack: return [0.62, 0.7, 0.55]
        case .triple: return [0.4, 0.5, 0.34]
        case .quad: return [0.5, 0.6, 0.4]
        case .focus, .full: return []
        }
    }

    public var ratioLabel: String {
        switch layout {
        case .split, .mainStack:
            let a = Int((ratio * 10).rounded()), b = 10 - a
            return mirrored ? "\(b):\(a)" : "\(a):\(b)"
        case .triple: return ratio >= 0.45 ? "宽中栏" : "均分"
        case .quad:
            let a = Int((ratio * 10).rounded()); return "\(a):\(10 - a)"
        case .focus, .full: return ""
        }
    }
}

public enum StageGeometry {
    /// AI 排布用：给的窗口数不够时退化成合适的版式（三栏只剩两个 → 左右；只剩一个 → 专注）。舞台本身不再自动退化
    public static func effective(_ spec: StageSpec, filled n: Int) -> StageSpec {
        guard n > 0, n < spec.layout.slots else { return spec }
        if n == 1 { return spec.layout == .full ? spec : StageSpec(.focus) }
        if n == 3 { return StageSpec(.mainStack, mirrored: spec.mirrored) }
        return StageSpec(.split, ratio: spec.layout == .mainStack ? spec.ratio : 0.5, mirrored: spec.mirrored)
    }

    /// 槽位顺序：0 号永远是「主位」。
    /// minWidths：某个槽位的窗口缩不到那么窄时（App 自带最小宽度），给它的最小宽度，其他栏让出空间
    public static func frames(_ spec: StageSpec, in rect: CGRect, gap g: CGFloat, minWidths: [Int: CGFloat] = [:]) -> [CGRect] {
        let r = rect.insetBy(dx: g, dy: g)
        func round(_ f: CGRect) -> CGRect {
            CGRect(x: f.minX.rounded(), y: f.minY.rounded(), width: f.width.rounded(), height: f.height.rounded())
        }
        switch spec.layout {
        case .full:
            return [round(r)]
        case .focus:
            // 宽屏上留白更多，笔记本上接近铺满
            let w = rect.width >= 1800 ? max(1100, rect.width * 0.62) : min(r.width, rect.width * 0.86)
            let ww = max(w, min(r.width, minWidths[0] ?? 0))
            return [round(CGRect(x: rect.midX - ww / 2, y: r.minY, width: ww, height: r.height))]
        case .split, .mainStack, .triple, .quad:
            // 列模型：从左到右的列，每列装哪些槽位（同一列内上下平分）
            var cols: [(share: Double, slots: [Int])]
            switch spec.layout {
            case .split: cols = [(spec.ratio, [0]), (1 - spec.ratio, [1])]
            case .mainStack: cols = [(spec.ratio, [0]), (1 - spec.ratio, [1, 2])]
            case .quad: cols = [(spec.ratio, [0, 2]), (1 - spec.ratio, [1, 3])]
            default: cols = [((1 - spec.ratio) / 2, [1]), (spec.ratio, [0]), ((1 - spec.ratio) / 2, [2])]
            }
            if spec.mirrored && spec.layout != .triple { cols.reverse() }
            let avail = r.width - g * CGFloat(cols.count - 1)
            var widths = cols.map { avail * CGFloat($0.share) }
            // 最小宽度：先满足有要求的列，剩下的按原比例分给其他列。
            // 别的列至少留原宽度的一半（不低于 360）；还放不下 = 有的 App 就是不肯变窄：允许互相盖住一部分，
            // 第一列靠左、最后一列靠右、中间的均匀错开，你点到哪个它就浮到最上面
            let need = cols.map { c in c.slots.compactMap { minWidths[$0] }.max() ?? 0 }
            let floor = widths.map { max(360, $0 * 0.5) }
            let want = widths.indices.map { need[$0] > 0 ? max(need[$0], widths[$0]) : floor[$0] }
            if need.contains(where: { $0 > 0 }), want.reduce(0, +) > avail {
                let ws = want.map { min($0, r.width) }
                var out = [CGRect](repeating: .zero, count: spec.layout.slots)
                let n = ws.count
                for (i, c) in cols.enumerated() {
                    // 左边缘从 r.minX 到「最后一列贴右边」之间均匀排开
                    let span = r.width - ws[n - 1]
                    var x = r.minX + (n > 1 ? span * CGFloat(i) / CGFloat(n - 1) : 0)
                    x = min(max(r.minX, x), r.maxX - ws[i])
                    let k = CGFloat(c.slots.count)
                    let h = (r.height - g * (k - 1)) / k
                    for (j, slot) in c.slots.enumerated() {
                        out[slot] = round(CGRect(x: x, y: r.minY + CGFloat(j) * (h + g), width: ws[i], height: h))
                    }
                }
                return out
            }
            if need.contains(where: { $0 > 0 }) {
                var fixed = Set<Int>()
                for _ in 0..<cols.count {
                    var changed = false
                    for i in widths.indices where !fixed.contains(i) && need[i] > widths[i] {
                        widths[i] = need[i]; fixed.insert(i); changed = true
                    }
                    let rest = avail - fixed.reduce(0) { $0 + widths[$1] }
                    let free = widths.indices.filter { !fixed.contains($0) }
                    let base = free.reduce(0.0) { $0 + cols[$1].share }
                    for i in free { widths[i] = max(floor[i], rest * CGFloat(cols[i].share / max(base, 0.01))) }
                    if !changed { break }
                }
            }
            var out = [CGRect](repeating: .zero, count: spec.layout.slots)
            var x = r.minX
            for (i, c) in cols.enumerated() {
                let n = CGFloat(c.slots.count)
                let h = (r.height - g * (n - 1)) / n
                for (j, slot) in c.slots.enumerated() {
                    out[slot] = round(CGRect(x: x, y: r.minY + CGFloat(j) * (h + g), width: widths[i], height: h))
                }
                x += widths[i] + g
            }
            return out
        }
    }
}

public struct DisplayStage: Equatable {
    public var spec: StageSpec
    /// 每个格子放谁（长度 = 版式的格子数，nil = 空着）。0 号 = 主位
    public var slots: [UInt32?]
    /// 当前在用的格子：⌘Tab 切来的窗口换进这里
    public var active: Int
    /// 锁住的格子：别的窗口不会把它换掉
    public var locked: Set<Int> = []
    /// 叠放：某个格子最上面那个窗口（key）下面还压着哪些窗口（从最底下到紧挨着它的那个）。
    /// 按最上面的窗口记，换位、换版式、拖到别的屏时整摞跟着走
    public var stacks: [UInt32: [UInt32]] = [:]
    /// 一摞最多几个窗口（含最上面那个）
    public static let maxStack = 5

    public init(spec: StageSpec, slots: [UInt32?], active: Int = 0, locked: Set<Int> = [], stacks: [UInt32: [UInt32]] = [:]) {
        self.spec = spec
        var s = Array(slots.prefix(spec.layout.slots))
        while s.count < spec.layout.slots { s.append(nil) }
        self.slots = s
        self.active = min(max(0, active), max(0, s.count - 1))
        self.locked = locked.filter { $0 < s.count }
        let tops = Set(s.compactMap { $0 })
        self.stacks = stacks.filter { tops.contains($0.key) && !$0.value.isEmpty }
    }

    /// 台上的窗口（每格最上面那个，按格子顺序，跳过空格）
    public var windows: [UInt32] { slots.compactMap { $0 } }
    /// 压在下面的窗口
    public var stacked: [UInt32] { slots.compactMap { $0 }.flatMap { stacks[$0] ?? [] } }
    /// 台上所有窗口（含压在下面的）
    public var allWindows: [UInt32] { windows + stacked }
    /// 某个格子下面压着几个
    public func depth(_ i: Int) -> Int { slots.indices.contains(i) ? slots[i].flatMap { stacks[$0]?.count } ?? 0 : 0 }
    public var emptySlots: [Int] { slots.indices.filter { slots[$0] == nil } }
    public func index(of id: UInt32) -> Int? { slots.firstIndex(of: id) }
}

// MARK: - 舞台
//
// 模型只有一条：每块屏幕 = 一个版式 + 几个格子，每个格子放一个窗口或空着。
// 不猜测、不自动降级版式。所有操作都只是「改某个格子放谁」，然后把窗口摆到格子的位置。

public final class StageManager {
    public private(set) var isActive = false
    public private(set) var stages: [String: DisplayStage] = [:]
    public var gap: CGFloat = 10
    public var autoPromote = true
    public var defaultSpec = StageSpec(.focus)
    /// 小于这个尺寸的窗口（小浮窗、设置面板）不参与舞台，原样悬浮。
    /// 上过台的窗口不受限制：三栏的侧栏可能只有 400 宽，不能因为被 Weft 摆窄了就变成「小浮窗」
    public var minSize = CGSize(width: 360, height: 260)
    /// 上过台的窗口
    public private(set) var everStaged = Set<UInt32>()
    /// 舞台在每块屏的哪个系统桌面上。你滑到别的桌面时，Weft 在那块屏上「暂停」：不藏、不吸、不自动上台
    private var spaceOf: [String: Int] = [:]
    /// 拔掉的屏幕上的舞台：插回来时恢复
    private var parked: [String: DisplayStage] = [:]

    /// 记下每块屏现在的桌面（进入舞台、摆场景、归位时）
    private func markSpaces() {
        let cur = actions.displaySpaces()
        for u in stages.keys { if let s = cur[u] { spaceOf[u] = s } }
    }

    /// 现在不在舞台那个桌面上的屏幕
    public func awayDisplays() -> Set<String> {
        let cur = actions.displaySpaces()
        return Set(spaceOf.compactMap { u, s in cur[u].map { $0 != s } == true ? u : nil })
    }
    /// 用户动过窗口后，等多久没有新动作才处理（磁吸归位）
    public var settleDelay: TimeInterval = 1.2
    public var log: (String) -> Void = { _ in }
    /// Weft 自己操作窗口后这段时间内的焦点变化不算用户切换
    public var promoteDelay: TimeInterval = 0.8
    /// 0 = 同步校验（测试用）
    public var verifyDelay: TimeInterval = 0.35

    private let actions: WindowActions
    private let stash: StashManager
    /// 进入舞台前的位置，退出时还原
    private var originals: [UInt32: CGRect] = [:]
    private var lastOwnAction = Date.distantPast
    /// 最近在用的屏幕
    public private(set) var focusedDisplay: String?
    /// 每个窗口的「家」：它属于哪块屏幕。从后台叫回来时回到自己的屏幕
    public private(set) var home: [UInt32: String] = [:]
    /// 面板（侧栏 / 总控）打开在哪块屏幕上，就操作哪块屏幕的舞台
    public var pinnedDisplay: String?
    /// 实测改不了尺寸的窗口：不参与舞台，原样悬浮
    public private(set) var fixed = Set<UInt32>()
    /// 实测的最小宽度（App Store 1000、微信 ~700…）：候选里标出「放不下」
    public private(set) var learnedMin: [UInt32: CGFloat] = [:]

    public init(actions: WindowActions, stash: StashManager) {
        self.actions = actions
        self.stash = stash
    }

    // MARK: 查询

    public func homeDisplay(_ id: UInt32) -> String? { home[id] }

    /// 随手 App（bundleID）：窗口原样悬浮，不上台、不藏
    public var floatingApps = Set<String>()

    // MARK: 附属窗口
    //
    // 台上的 App 自己弹出来的新窗口（微信看图、预览、设置面板、对话框……）：不当成新窗口，
    // 不进格子、不问「放进哪一块」、不单独开场景，就在 App 放的位置浮着；它的 App 下台时一起退到后台。
    // 想把它放进格子：从侧栏 / 总控点它的「放进舞台」。

    /// 现在浮着的附属窗口
    public var companions = Set<UInt32>()
    /// 界面层告诉舞台：这个窗口是不是某个场景的成员（是的话不算附属窗口，照场景来）
    public var isSceneMember: ((WindowInfo) -> Bool)?
    /// 每个窗口第一次出现的时间（判断「刚弹出来的」）
    private var firstSeen: [UInt32: Date] = [:]
    private var seenBaseline = false
    /// 弹出来多久以内算「刚弹出来」
    public var freshWindow: TimeInterval = 4

    /// 进舞台时：现在开着的都算「原来就有的」
    func rebaseline(_ live: [WindowInfo]) { seenBaseline = false; firstSeen = [:]; companions = []; noteSeen(live) }

    func noteSeen(_ live: [WindowInfo]) {
        let now = Date()
        // 第一次看到的这一批是原来就开着的，不算新弹出来
        let stamp = seenBaseline ? now : .distantPast
        for w in live where firstSeen[w.id] == nil { firstSeen[w.id] = stamp }
        seenBaseline = true
        let ids = Set(live.map(\.id))
        firstSeen = firstSeen.filter { ids.contains($0.key) }
        companions.formIntersection(ids)
    }

    /// 刚弹出来、而且它的 App 有窗口正在台上：返回台上那个窗口（它的「主窗口」）
    public func companionParent(of w: WindowInfo, live: [WindowInfo]) -> WindowInfo? {
        guard !isOnStage(w.id), !everStaged.contains(w.id), !stash.isStashed(w.id) else { return nil }
        // 第一次见到它（还没记过）也算刚弹出来；原来就开着的在进舞台时已经记成「很早以前」
        if let t = firstSeen[w.id], Date().timeIntervalSince(t) > freshWindow { return nil }
        if firstSeen[w.id] == nil { firstSeen[w.id] = Date() }
        if isSceneMember?(w) == true { return nil }
        let on = onStage
        return live.first { $0.id != w.id && $0.bundleID == w.bundleID && on.contains($0.id) }
    }

    /// 看看这个窗口是不是附属窗口；是就记下来（之后不进格子、不被藏）
    @discardableResult
    public func adoptCompanion(_ w: WindowInfo, live: [WindowInfo]) -> Bool {
        if companions.contains(w.id) { return true }
        guard let parent = companionParent(of: w, live: live) else { return false }
        companions.insert(w.id)
        log("附属窗口：\(w.appName)「\(w.title)」跟着 \(parent.title.isEmpty ? parent.appName : parent.title)，浮着不进格子")
        return true
    }

    public func stageable(_ w: WindowInfo) -> Bool {
        w.axAvailable && w.fixedSize != true && !fixed.contains(w.id) && !floatingApps.contains(w.bundleID)
            && (everStaged.contains(w.id) || (w.frame.width >= minSize.width && w.frame.height >= minSize.height))
    }

    /// 这个窗口能不能放进这么宽的格子
    public func fits(_ id: UInt32, width: CGFloat) -> Bool { (learnedMin[id] ?? 0) <= width + 40 }

    public var onStage: Set<UInt32> { Set(stages.values.flatMap(\.allWindows)) }
    public func isOnStage(_ id: UInt32) -> Bool { locate(id) != nil || stackLocate(id) != nil }

    /// 压在某一摞下面的窗口：在哪块屏、哪一格、那一摞最上面是谁
    public func stackLocate(_ id: UInt32) -> (display: String, slot: Int, top: UInt32)? {
        for (u, s) in stages {
            for (top, m) in s.stacks where m.contains(id) {
                if let i = s.index(of: top) { return (u, i, top) }
            }
        }
        return nil
    }

    public func locate(_ id: UInt32) -> (display: String, slot: Int)? {
        for (u, s) in stages { if let i = s.index(of: id) { return (u, i) } }
        return nil
    }

    public func stage(for display: String?) -> DisplayStage? { display.flatMap { stages[$0] } }

    /// 接下来的操作作用于这块屏（版式盘弹在哪块屏就是哪块）
    public func focus(display u: String) { if actions.profile().display(uuid: u) != nil { focusedDisplay = u } }

    /// 当前操作的屏幕：面板所在 → 最近用过的 → 主屏
    public func currentDisplay() -> String? {
        let prof = actions.profile()
        if let f = pinnedDisplay, prof.display(uuid: f) != nil { return f }
        if let f = focusedDisplay, prof.display(uuid: f) != nil { return f }
        return prof.main?.uuid
    }

    /// 某块屏每个格子的位置（CG 坐标，含空格子）
    public func slotFrames(_ u: String) -> [CGRect] {
        guard let st = stages[u], let d = actions.profile().display(uuid: u) else { return [] }
        return frames(st, in: d.visible)
    }

    /// 某个（不一定在台上的）舞台摆在某块屏上时每一格的位置，算上已知的最小宽度
    public func frames(for st: DisplayStage, display u: String) -> [CGRect] {
        guard let d = actions.profile().display(uuid: u) else { return [] }
        return frames(st, in: d.visible)
    }

    private func frames(_ st: DisplayStage, in rect: CGRect) -> [CGRect] {
        var fr = baseFrames(st, in: rect)
        // 叠着的格子：最上面那个往右下错开（下面压几个就错开几步）
        for (i, id) in st.slots.enumerated() where i < fr.count {
            if let id, let n = st.stacks[id]?.count, n > 0 { fr[i] = Self.layer(fr[i], n, of: n) }
        }
        return fr
    }

    /// 不算叠放的格子位置（整摞占的范围）
    private func baseFrames(_ st: DisplayStage, in rect: CGRect) -> [CGRect] {
        var mins: [Int: CGFloat] = [:]
        for (i, id) in st.slots.enumerated() { if let id, let m = learnedMin[id] { mins[i] = m } }
        return StageGeometry.frames(st.spec, in: rect, gap: gap, minWidths: mins)
    }

    /// 某块屏每格整摞占的范围（不算错开）
    public func baseSlotFrames(_ u: String) -> [CGRect] {
        guard let st = stages[u], let d = actions.profile().display(uuid: u) else { return [] }
        return baseFrames(st, in: d.visible)
    }

    /// 叠放每层错开多少
    public static let stackStep: CGFloat = 18

    /// 一摞里第 k 层（0 = 最底下）的位置：越往上越往右下，下面的露出左边和上边一条
    public static func layer(_ f: CGRect, _ k: Int, of n: Int) -> CGRect {
        let d = stackStep
        return CGRect(x: f.minX + CGFloat(k) * d, y: f.minY + CGFloat(k) * d,
                      width: max(200, f.width - CGFloat(n) * d), height: max(150, f.height - CGFloat(n) * d))
    }

    /// 压在下面的窗口各自该在的位置
    private func stackTargets(_ st: DisplayStage, in rect: CGRect) -> [UInt32: CGRect] {
        let base = baseFrames(st, in: rect)
        var out: [UInt32: CGRect] = [:]
        for (i, top) in st.slots.enumerated() where i < base.count {
            guard let top, let m = st.stacks[top], !m.isEmpty else { continue }
            for (k, id) in m.enumerated() { out[id] = Self.layer(base[i], k, of: m.count) }
        }
        return out
    }

    /// 某块屏上压在下面的窗口的位置（界面画缩略图 / 调试用）
    public func stackFrames(_ u: String) -> [UInt32: CGRect] {
        guard let st = stages[u], let d = actions.profile().display(uuid: u) else { return [:] }
        return stackTargets(st, in: d.visible)
    }

    // MARK: 进出

    /// 进入舞台：每块屏幕把最前面的窗口（或当前窗口）请上台，其余退到后台
    public func enter(focused: UInt32?) {
        guard !isActive, actions.canObserve else { return }
        let live = actions.windows()
        let prof = actions.profile()
        remember(live, prof)
        rebaseline(live)
        for d in prof.displays {
            let here = live.filter { stageable($0) && !$0.isMinimized && !stash.isStashed($0.id) && $0.displayUUID == d.uuid }
                .sorted { $0.zIndex < $1.zIndex }
            guard let first = here.first(where: { $0.id == focused }) ?? here.first else { continue }
            stages[d.uuid] = DisplayStage(spec: defaultSpec, slots: [first.id])
            if first.id == focused { focusedDisplay = d.uuid }
        }
        isActive = true
        touch()
        markSpaces()
        sweep(live)
        layoutAll()
        if let f = focused, isOnStage(f) { actions.focus(f) }
        log("进入舞台模式：\(stages.count) 块屏幕")
    }

    private func remember(_ live: [WindowInfo], _ prof: DisplayProfile) {
        for w in live where originals[w.id] == nil {
            let o = stash.entry(w.id)?.originalFrame ?? w.frame
            originals[w.id] = o
            if let u = prof.display(containing: o.center)?.uuid ?? w.displayUUID { home[w.id] = u }
        }
    }

    /// 退出：后台窗口回到原位，台上窗口保持现在的样子
    @discardableResult
    public func exit() -> Bool {
        guard isActive else { return true }
        guard actions.canObserve else { log("锁屏中，等解锁后再退出舞台"); return false }
        let live = Set(actions.windows().map(\.id))
        for e in stash.entries where e.byStage == true {
            if live.contains(e.windowID) { stash.unstash(e.windowID, focus: false) }
            else if !actions.exists(e.windowID) { stash.release(e.windowID) }
        }
        stages.removeAll()
        originals.removeAll()
        home.removeAll()
        spaceOf.removeAll()
        parked.removeAll()
        isActive = false
        log("退出舞台模式")
        return true
    }

    // MARK: 放窗口

    /// 把窗口放进某个格子。slot 为 nil 时自动挑：有空格先填空格 → 当前在用的格子 → 第一个没锁的格子。
    /// 被换下来的窗口退到后台；如果这个窗口本来就在台上别的格子里，两个格子互换。
    /// 返回 false = 没地方放（格子全锁着）
    @discardableResult
    public func present(_ w: WindowInfo, on display: String? = nil, slot: Int? = nil, focus: Bool = true) -> Bool {
        guard isActive else { return false }
        if stackLocate(w.id) != nil, display == nil, slot == nil { return raiseInStack(w.id, focus: focus) }
        if stackLocate(w.id) != nil { unstack(w.id) }
        touch()
        companions.remove(w.id)
        // 已经在台上
        if let (u, i) = locate(w.id), display == nil || display == u {
            if let slot, slot != i, slot < stages[u]!.slots.count {
                snapshot()
                stages[u]!.slots.swapAt(i, slot)
                stages[u]!.active = slot
                layout(u)
            } else {
                stages[u]!.active = i
            }
            focusedDisplay = u
            if focus { actions.focus(w.id) }
            return true
        }
        guard let target = display ?? targetDisplay(for: w) else { return false }
        var st = stages[target] ?? DisplayStage(spec: defaultSpec, slots: [])
        let idx: Int
        if let slot, slot < st.slots.count { idx = slot }
        else if let e = st.emptySlots.first { idx = e }
        else if !st.locked.contains(st.active) { idx = st.active }
        else if let f = st.slots.indices.first(where: { !st.locked.contains($0) }) { idx = f }
        else { return false }

        snapshot()
        var displaced = st.slots[idx]
        // 从别的屏换过来：原来的格子空出来（或者和被换下的窗口互换位置）
        if let (u, i) = locate(w.id) {
            stages[u]!.slots[i] = nil
            if let d = displaced, !stages[u]!.locked.contains(i) {
                stages[u]!.slots[i] = d; home[d] = u; displaced = nil
            }
            if u != target { layout(u) }
        }
        bringBack(w)
        st.slots[idx] = w.id
        st.active = idx
        stages[target] = st
        focusedDisplay = target
        home[w.id] = target
        layout(target)
        if focus { actions.focus(w.id) }
        if let o = displaced { hide(o); pushHistory(target, idx, o) }
        return true
    }

    // MARK: 叠放

    /// 最上面的窗口没了、换了：一摞里剩下的怎么办。空格子 → 下面那个顶上来；最上面被换成了别的窗口 → 整摞退到后台
    private func tidyStacks(_ u: String) {
        guard var st = stages[u], !st.stacks.isEmpty else { return }
        let tops = Set(st.slots.compactMap { $0 })
        for (top, m) in st.stacks where !tops.contains(top) {
            st.stacks[top] = nil
            var rest = m
            // 原来那一格空了（关掉 / 请走了）：最上面那层顶上来
            if let i = lastSlot[top], st.slots.indices.contains(i), st.slots[i] == nil, let next = rest.popLast() {
                st.slots[i] = next
                if !rest.isEmpty { st.stacks[next] = rest }
                log("一摞最上面的没了，下面的顶上来：\(next)")
                continue
            }
            for id in rest { hide(id) }
        }
        stages[u] = st
    }

    /// 每个窗口上次在第几格（判断「这一格空出来的是不是那一摞」）
    private var lastSlot: [UInt32: Int] = [:]
    private func recordSlots(_ u: String) {
        guard let st = stages[u] else { return }
        for (i, id) in st.slots.enumerated() { if let id { lastSlot[id] = i } }
    }

    /// 这一格够不够大、能不能叠（太小的格子叠了每层都看不清）
    public func canStack(display u: String, slot i: Int) -> Bool {
        guard let st = stages[u], let d = actions.profile().display(uuid: u), !st.locked.contains(i) else { return false }
        let base = baseFrames(st, in: d.visible)
        return base.indices.contains(i) && base[i].width >= 640 && base[i].height >= 420
    }

    /// 把窗口叠到某一格上（它成为最上面的，原来的压下去）。一摞满 5 个时最底下那个退到后台
    @discardableResult
    public func stackOnto(_ w: WindowInfo, display u: String, slot i: Int) -> Bool {
        guard isActive, var st = stages[u], st.slots.indices.contains(i), !st.locked.contains(i) else { return false }
        if st.slots[i] != nil && !canStack(display: u, slot: i) { log("格子太小，不叠：\(i)"); return false }
        if st.slots[i] == w.id { return true }
        touch(); snapshot()
        companions.remove(w.id)
        // 从原来的地方拿出来
        var carried: [UInt32] = []
        if let (v, j) = locate(w.id) {
            carried = stages[v]!.stacks.removeValue(forKey: w.id) ?? []
            stages[v]!.slots[j] = nil
            if v != u { shrink(v); layout(v); onMovedAway(w.id, v) }
        } else if let (v, _, top) = stackLocate(w.id) {
            stages[v]!.stacks[top]?.removeAll { $0 == w.id }
            if v != u { layout(v); onMovedAway(w.id, v) }
        }
        st = stages[u]!
        bringBack(w)
        var pile = carried
        if let old = st.slots[i] {
            pile = (st.stacks.removeValue(forKey: old) ?? []) + [old] + carried
        }
        pile.removeAll { $0 == w.id }
        while pile.count > DisplayStage.maxStack - 1 {
            let out = pile.removeFirst()
            hide(out)
            pushHistory(u, i, out)
        }
        st.slots[i] = w.id
        if !pile.isEmpty { st.stacks[w.id] = pile }
        st.active = i
        stages[u] = st
        home[w.id] = u
        focusedDisplay = u
        layout(u)
        actions.focus(w.id)
        log("叠上去：\(w.appName) → 格子 \(i)（这一摞 \(pile.count + 1) 个）")
        onRelayout(u)
        return true
    }

    /// 一摞里的某个窗口翻到最上面（点了露出来的边、转轮选中）。原来最上面的压到它下面一层
    @discardableResult
    public func raiseInStack(_ id: UInt32, focus: Bool = true) -> Bool {
        guard let (u, i, top) = stackLocate(id), var st = stages[u] else { return false }
        touch()
        var m = st.stacks.removeValue(forKey: top) ?? []
        m.removeAll { $0 == id }
        m.append(top)
        st.slots[i] = id
        st.stacks[id] = m
        st.active = i
        stages[u] = st
        focusedDisplay = u
        layout(u)
        if focus { actions.focus(id) }
        log("翻到最上面：\(id)")
        onRelayout(u)
        return true
    }

    /// 整摞一起摆出来（换场景）时，按从下到上的顺序点一遍，叠的前后才对
    private var needsOrder = Set<String>()
    private func orderStacks() {
        for u in needsOrder {
            guard let st = stages[u] else { continue }
            for (top, m) in st.stacks { for id in m { actions.focus(id) }; actions.focus(top) }
        }
        needsOrder.removeAll()
    }

    /// 从一摞里拿出来（不藏）
    public func unstack(_ id: UInt32) {
        guard let (u, _, top) = stackLocate(id) else { return }
        touch()
        stages[u]!.stacks[top]?.removeAll { $0 == id }
        if stages[u]!.stacks[top]?.isEmpty == true { stages[u]!.stacks[top] = nil }
        layout(u)
    }

    // MARK: 拖进来插入

    /// 把一个窗口拖到某块屏上松手时会怎样：放进哪一格、版式变成什么、它会在哪
    public struct InsertPlan: Equatable {
        public let display: String
        public let spec: StageSpec
        public let slots: [UInt32?]
        /// 这个窗口落下后的位置（画落点预览用）
        public let frame: CGRect
        /// 格子满了（四宫格）时被换下去的窗口
        public let replaces: UInt32?
    }

    /// 从别处（另一块屏、浮着的窗口）拖到这块屏：有空格放空格；没有就版式长一格（专注→左右→一主两辅 / 三栏→四宫格），
    /// 按你松手的位置插在那个窗口前面或后面；四宫格满了就换掉落点那一格。同一块屏里拖还是换位（不走这里）
    public func planInsert(_ id: UInt32, display u: String, at p: CGPoint) -> InsertPlan? {
        guard isActive, let st = stages[u], let d = actions.profile().display(uuid: u), !st.slots.contains(id) else { return nil }
        let cur = frames(st, in: d.visible)
        func reading(_ fr: [CGRect], _ idx: [Int]) -> [Int] {
            idx.sorted { a, b in abs(fr[a].midX - fr[b].midX) > 40 ? fr[a].midX < fr[b].midX : fr[a].midY < fr[b].midY }
        }
        func plan(_ spec: StageSpec, _ slots: [UInt32?], replaces: UInt32? = nil) -> InsertPlan? {
            let ds = DisplayStage(spec: spec, slots: slots)
            guard let j = ds.slots.firstIndex(of: id) else { return nil }
            let fr = frames(ds, in: d.visible)
            return InsertPlan(display: u, spec: spec, slots: ds.slots, frame: fr[j], replaces: replaces)
        }
        // 1. 有空格：落点那一格空着就放那儿，不然放第一个空格
        let empties = st.emptySlots.filter { cur.indices.contains($0) }
        if let j = empties.first(where: { cur[$0].contains(p) }) ?? empties.first {
            var s = st.slots; s[j] = id
            return plan(st.spec, s)
        }
        let filled = st.slots.indices.filter { st.slots[$0] != nil && $0 < cur.count }
        let wide = d.visible.width >= 2000
        let next: StageSpec?
        switch filled.count {
        case 0, 1: next = StageSpec(.split, ratio: 0.5)
        case 2: next = wide ? StageSpec(.triple, ratio: 0.34) : StageSpec(.mainStack, ratio: 0.62, mirrored: st.spec.mirrored)
        case 3: next = StageSpec(.quad)
        default: next = nil
        }
        // 2. 满了：换掉落点那一格（锁着的不换）
        guard let ns = next else {
            guard let j = cur.indices.first(where: { cur[$0].contains(p) }), !st.locked.contains(j) else { return nil }
            var s = st.slots; let old = s[j]; s[j] = id
            return plan(st.spec, s, replaces: old)
        }
        // 3. 长一格：现有窗口按从左到右、从上到下的顺序，新窗口插在落点那个窗口的前面（落在它左半边/上半边）或后面
        var list = reading(cur, filled).map { st.slots[$0]! }
        var k = p.x < d.visible.midX ? 0 : list.count
        if let hit = filled.first(where: { cur[$0].contains(p) }), let pos = list.firstIndex(of: st.slots[hit]!) {
            let f = cur[hit]
            // 它上下还叠着别的窗口（一主两辅的右栏、四宫格）：按上下半边算；否则按左右半边
            let stacked = filled.contains { $0 != hit && abs(cur[$0].midX - f.midX) < 40 }
            let before = stacked ? p.y < f.midY : p.x < f.midX
            k = before ? pos : pos + 1
        }
        list.insert(id, at: k)
        let nf = StageGeometry.frames(ns, in: d.visible, gap: gap)
        var s = [UInt32?](repeating: nil, count: ns.layout.slots)
        for (pos, slot) in reading(nf, Array(nf.indices)).enumerated() where pos < list.count { s[slot] = list[pos] }
        return plan(ns, s)
    }

    /// 按 planInsert 的结果真的放进去
    @discardableResult
    public func insert(_ w: WindowInfo, plan pl: InsertPlan) -> Bool {
        guard isActive, stages[pl.display] != nil else { return false }
        touch(); snapshot()
        companions.remove(w.id)
        var carried: [UInt32] = []
        if let (u, i) = locate(w.id), u != pl.display {
            carried = stages[u]!.stacks.removeValue(forKey: w.id) ?? []
            stages[u]!.slots[i] = nil
            shrink(u)
            layout(u); onMovedAway(w.id, u); onRelayout(u)
        }
        if let (u, _, _) = stackLocate(w.id) {
            unstack(w.id)
            if u != pl.display { onMovedAway(w.id, u) }
        }
        bringBack(w)
        let old = stages[pl.display]!
        var stacks = old.stacks
        if !carried.isEmpty { stacks[w.id] = carried }
        if let r = pl.replaces { for id in stacks.removeValue(forKey: r) ?? [] { hide(id) } }
        var st = DisplayStage(spec: pl.spec, slots: pl.slots, locked: pl.spec == old.spec ? old.locked : [], stacks: stacks)
        st.active = st.slots.firstIndex(of: w.id) ?? 0
        stages[pl.display] = st
        home[w.id] = pl.display
        focusedDisplay = pl.display
        layout(pl.display)
        actions.focus(w.id)
        if let o = pl.replaces { hide(o); pushHistory(pl.display, st.active, o) }
        log("拖进来插入：\(w.appName) → \(pl.spec.layout) 第 \(st.active) 格")
        onRelayout(pl.display)
        return true
    }

    /// 把某个格子清空（窗口退到后台，格子留着）
    public func clear(display u: String, slot: Int) {
        guard var st = stages[u], st.slots.indices.contains(slot), let id = st.slots[slot] else { return }
        touch()
        snapshot()
        st.slots[slot] = nil
        stages[u] = st
        hide(id)
        // 下面压着窗口：顶上来
        if st.stacks[id] != nil { layout(u) }
    }

    /// 放手：从格子里拿下来，但不藏（变成随手窗口时用）
    public func letGo(_ id: UInt32) {
        if stackLocate(id) != nil { unstack(id); return }
        guard let (u, i) = locate(id), var st = stages[u] else { return }
        touch()
        st.slots[i] = nil
        stages[u] = st
    }

    /// 把台上的窗口请下去（格子空出来）
    public func dismiss(_ id: UInt32) {
        if stackLocate(id) != nil { unstack(id); hide(id); return }
        guard let (u, i) = locate(id) else { return }
        clear(display: u, slot: i)
        if let s = stages[u], let other = s.slots[s.active] ?? s.windows.first { actions.focus(other) }
    }

    public func toggleLock(display u: String, slot: Int) {
        guard stages[u]?.slots.indices.contains(slot) == true else { return }
        if stages[u]!.locked.contains(slot) { stages[u]!.locked.remove(slot) } else { stages[u]!.locked.insert(slot) }
    }

    /// 换版式：已有的窗口按顺序留在前面的格子，多出来的退到后台，不够的格子空着（界面在空格子里弹候选）。
    /// fill：AI 排布 / 场景直接给出的窗口，按顺序填进空格子
    public func setSpec(_ spec: StageSpec, display: String? = nil, fill candidates: [WindowInfo] = []) {
        guard isActive, let u = display ?? currentDisplay() else { return }
        touch()
        snapshot()
        let old = stages[u]
        // 窗口按旧格子顺序排，空格子去掉；锁住的格子尽量保持同一个编号
        let keep = old?.windows ?? []
        var st = DisplayStage(spec: spec, slots: Array(keep.prefix(spec.layout.slots)), active: old?.active ?? 0,
                              locked: old?.locked ?? [], stacks: old?.stacks ?? [:])
        for t in keep.dropFirst(spec.layout.slots) { for id in old?.stacks[t] ?? [] { hide(id) } }
        let overflow = keep.dropFirst(spec.layout.slots)
        for c in candidates where !st.emptySlots.isEmpty && !isOnStage(c.id) && !st.slots.contains(c.id) && stageable(c) {
            bringBack(c)
            home[c.id] = u
            st.slots[st.emptySlots[0]] = c.id
        }
        stages[u] = st
        layout(u)
        for id in overflow { hide(id) }
        // 换版式就是「我要干净」：顺手把跳回屏幕上的后台窗口再藏一次
        stash.enforce(live: actions.windows(), except: onStage)
    }

    /// 两个格子互换（同一块屏）
    public func swap(display u: String, _ a: Int, _ b: Int) {
        guard var st = stages[u], st.slots.indices.contains(a), st.slots.indices.contains(b), a != b else { return }
        touch()
        snapshot()
        st.slots.swapAt(a, b)
        // 「在用的格子」跟着窗口走
        if st.active == a { st.active = b } else if st.active == b { st.active = a }
        stages[u] = st
        layout(u)
    }

    /// 主位和副位互换
    public func swapMain(display: String? = nil) {
        guard let u = display ?? currentDisplay() else { return }
        swap(display: u, 0, 1)
    }

    /// 直接摆出一整套场景（AI 排布、事情的摆放）
    public func apply(scene: [(display: String, spec: StageSpec, windows: [UInt32])]) {
        applySlots(scene.map { ($0.display, $0.spec, $0.windows.map { Optional($0) }) }, compact: true)
    }

    /// 按格子摆：slots[i] = 第 i 格放谁（nil = 空着，位置不挪）。compact = 去掉找不到的窗口、往前补（AI 排布用）
    public func applySlots(_ scene: [(display: String, spec: StageSpec, slots: [UInt32?])], compact: Bool = false) {
        applySlots(scene.map { ($0.display, $0.spec, $0.slots, [UInt32: [UInt32]]()) }, compact: compact)
    }

    /// 同上，带叠放（key = 那一格最上面的窗口，value = 压在下面的，从最底下开始）
    public func applySlots(_ scene: [(display: String, spec: StageSpec, slots: [UInt32?], stacks: [UInt32: [UInt32]])], compact: Bool = false) {
        let live = actions.windows()
        if !isActive {
            remember(live, actions.profile())
            rebaseline(live)
            isActive = true
        }
        touch()
        snapshot()
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var placed = Set<UInt32>()
        for s in scene {
            var slots: [UInt32?] = s.slots.map { id in
                guard let id, byID[id] != nil, !placed.contains(id) else { return nil }
                placed.insert(id)
                return id
            }
            if compact { slots = slots.compactMap { $0 }.map { Optional($0) } }
            slots = Array(slots.prefix(s.spec.layout.slots))
            let ids = slots.compactMap { $0 }
            guard !ids.isEmpty else { continue }
            var stacks: [UInt32: [UInt32]] = [:]
            for (top, m) in s.stacks where ids.contains(top) {
                let ok = Array(m.filter { byID[$0] != nil && !placed.contains($0) && !ids.contains($0) }.suffix(DisplayStage.maxStack - 1))
                ok.forEach { placed.insert($0) }
                if !ok.isEmpty { stacks[top] = ok }
            }
            let all = ids + stacks.values.flatMap { $0 }
            for id in all {
                companions.remove(id)
                if let (u, i) = locate(id), u != s.display { stages[u]!.slots[i] = nil }
                if let (u, _, top) = stackLocate(id), u != s.display { stages[u]!.stacks[top]?.removeAll { $0 == id } }
                bringBack(byID[id]!)
                home[id] = s.display
            }
            // 被替换下来的窗口（含压在下面的）
            for id in stages[s.display]?.allWindows ?? [] where !all.contains(id) { hide(id) }
            stages[s.display] = DisplayStage(spec: s.spec, slots: slots, stacks: stacks)
            needsOrder.insert(s.display)
        }
        markSpaces()
        sweep(actions.windows())
        layoutAll()
        orderStacks()
        if let first = scene.first, let id = stages[first.display]?.windows.first {
            focusedDisplay = first.display
            actions.focus(id)
        }
    }

    // MARK: 跟随用户

    public enum FocusResult { case promoted, onStage, ignored, later }

    /// 不在台上的窗口被切到前面时，先问界面层要不要自己处理（返回 true = 处理了）
    public var activationHandler: ((WindowInfo) -> Bool)?

    /// 格子里的窗口没了，要不要让刚才在这格的窗口补回来（界面层：存好的场景里 App 退了 → 位置留着等它）
    public var refillAllowed: (String, Int) -> Bool = { _, _ in true }

    /// 你亲手把窗口从一块屏拖到了另一块屏（窗口, 原来那块屏）：界面层据此把它从原来那块屏的场景里拿掉
    public var onMovedAway: (UInt32, String) -> Void = { _, _ in }

    /// 窗口被拖去别的屏以后，这块屏剩下的窗口收紧：版式缩一格（四宫格→一主两辅→左右→专注），不留一个空格子。
    /// 拖进来长一格，拖走缩一格。原来就有空格子（故意空着的）、有锁住的格子、或者一个都不剩时不动
    private func shrink(_ u: String) {
        guard let st = stages[u], st.locked.isEmpty, st.emptySlots.count == 1 else { return }
        let ids = st.windows
        guard !ids.isEmpty else { return }
        let spec = StageGeometry.effective(st.spec, filled: ids.count)
        guard spec != st.spec else { return }
        let act = st.slots.indices.contains(st.active) ? st.slots[st.active] : nil
        var ns = DisplayStage(spec: spec, slots: ids.map { Optional($0) }, stacks: st.stacks)
        ns.active = act.flatMap { ns.slots.firstIndex(of: $0) } ?? 0
        stages[u] = ns
        log("窗口拖走了，版式收紧成 \(spec.layout)")
    }

    /// 把一块屏清空（空桌面）：台上的窗口都退到后台，留一个空的专注格
    public func clearAll(display u: String) {
        guard isActive, actions.profile().display(uuid: u) != nil else { return }
        touch(); snapshot()
        for id in stages[u]?.allWindows ?? [] { hide(id) }
        stages[u] = DisplayStage(spec: StageSpec(.focus), slots: [])
        focusedDisplay = u
        layout(u)
        onRelayout(u)
    }

    /// 用户切到了某个窗口（⌘Tab、点 Dock、通知……）：不在台上就换进当前格子
    @discardableResult
    public func onFocus(_ id: UInt32) -> Bool { focusChanged(id) == .promoted }

    /// .later = 刚好在 Weft 自己摆窗口的那一小会儿里：等一下再判断（以前这种切换会被直接丢掉，⌘Tab 了却没上台）
    public func focusChanged(_ id: UInt32) -> FocusResult {
        guard isActive, actions.canObserve else { return .ignored }
        if let (u, i) = locate(id) {
            focusedDisplay = u
            stages[u]!.active = i
            return .onStage
        }
        // 点了一摞里露出来的那条边：它翻到最上面（Weft 自己刚摆完不算；鼠标还按着可能在拖，松开再说）
        if stackLocate(id) != nil {
            guard Date().timeIntervalSince(lastOwnAction) >= promoteDelay else { return .ignored }
            if CGEventSource.buttonState(.combinedSessionState, button: .left) { return .later }
            return raiseInStack(id, focus: false) ? .promoted : .ignored
        }
        guard autoPromote else { return .ignored }
        guard Date().timeIntervalSince(lastOwnAction) >= promoteDelay else { return .later }
        let w = actions.windows().first(where: { $0.id == id })
        guard let w, stageable(w), !w.isMinimized else { return .ignored }
        if adoptCompanion(w, live: actions.windows()) { return .ignored }
        // 你在别的系统桌面上用窗口：那是舞台以外的地方，不管
        if let u = w.displayUUID, awayDisplays().contains(u) { return .ignored }
        // 界面层接管（场景模式：切到这个窗口所在的场景，或单独开一个新场景）
        if let h = activationHandler, h(w) { touch(); return .promoted }
        guard present(w, focus: false) else { return .ignored }
        log("自动上台：\(w.appName) \(w.title)")
        return .promoted
    }

    /// 定期对账：关掉 / 最小化 / 隐藏的窗口让出格子（刚才在这个格子里的窗口补回来）、新冒出来的杂窗口退到后台
    public func reconcile(mru: [UInt32] = []) {
        guard isActive, actions.canObserve else { return }
        let live = actions.windows()
        noteSeen(live)
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let prof = actions.profile()
        let settled = Date().timeIntervalSince(lastOwnAction) >= promoteDelay * 2
        let away = awayDisplays()
        for u in Array(stages.keys) where !away.contains(u) {
            // 屏幕暂时看不到（锁屏、睡眠、正在插拔）：先不动它，插拔由显示器变化的流程统一处理
            guard prof.display(uuid: u) != nil else { continue }
            var changed = false
            for (i, id) in stages[u]!.slots.enumerated() {
                guard let id else { continue }
                var why: String?
                if byID[id] == nil, !actions.exists(id) { why = "关掉了" }
                // 你把它最小化 / ⌘H 隐藏了 = 不想看它：请下台（刚 Weft 自己操作完的那一下不算，状态还没刷新）
                else if settled, let w = byID[id], w.isMinimized { why = "最小化了" }
                else if settled, let w = byID[id], w.pid > 0, NSRunningApplication(processIdentifier: w.pid)?.isHidden == true { why = "隐藏了" }
                guard let why else { continue }
                stages[u]!.slots[i] = nil
                changed = true
                // 下面压着窗口：最上面那层顶上来（不从历史里找）
                if var m = stages[u]!.stacks.removeValue(forKey: id), let next = m.popLast() {
                    stages[u]!.slots[i] = next
                    if !m.isEmpty { stages[u]!.stacks[next] = m }
                    log("\(why)，这一摞下面的顶上来 \(next)")
                    continue
                }
                if !refillAllowed(u, i) { log("\(why)，格子留着等它回来") }
                else if let back = refill(u, i, byID) { log("\(why)，格子里补回刚才的窗口 \(back)") } else { log("\(why)，格子空出来") }
            }
            // 压在下面的：关了 / 最小化 / 隐藏了就从这一摞里拿掉
            for (top, m) in stages[u]!.stacks {
                let keep = m.filter { id in
                    guard let w = byID[id] else { return actions.exists(id) }
                    return !(settled && (w.isMinimized || (w.pid > 0 && NSRunningApplication(processIdentifier: w.pid)?.isHidden == true)))
                }
                if keep != m { stages[u]!.stacks[top] = keep.isEmpty ? nil : keep; changed = true; log("一摞里少了 \(m.count - keep.count) 个") }
            }
            if changed { layout(u); onRelayout(u) }
        }
        guard settled else { return }
        let hidden = sweep(live)
        // 后台记录说藏着、其实又回到屏幕上的（App Store 这类会自己把窗口拉回来）：再藏一次
        let front = live.filter(\.axAvailable).min { $0.zIndex < $1.zIndex }?.id
        if stash.enforce(live: live.filter { $0.displayUUID.map { !away.contains($0) } ?? true }, except: hidden.union(onStage).union([front].compactMap { $0 })) > 0 {
            log("重新藏好被拉回屏幕的后台窗口")
        }
    }

    /// 关掉 / 最小化后：刚才在这个格子里的窗口回来（像关掉一个标签页，回到上一个）
    private func refill(_ u: String, _ i: Int, _ byID: [UInt32: WindowInfo]) -> UInt32? {
        while let id = slotHistory[u]?[i]?.popLast() {
            guard let w = byID[id], stash.isStashed(id), !isOnStage(id), stageable(w), !w.isMinimized else { continue }
            bringBack(w)
            stages[u]!.slots[i] = id
            home[id] = u
            return id
        }
        return nil
    }

    private var slotHistory: [String: [Int: [UInt32]]] = [:]
    private func pushHistory(_ u: String, _ i: Int, _ id: UInt32) {
        var a = slotHistory[u]?[i] ?? []
        a.removeAll { $0 == id }
        a.append(id)
        slotHistory[u, default: [:]][i] = Array(a.suffix(6))
    }

    // MARK: 磁吸：窗口被手动挪了、拉了、App 自己跑偏了

    private var mouseWasDown = false
    private var driftSince: [UInt32: Date] = [:]
    private var snapTries: [UInt32: Int] = [:]
    /// 临时铺满的窗口（双击标题栏、绿色按钮全屏、系统平铺的「填充」）：尊重它，等它自己缩回来再归位
    public private(set) var zoomed = Set<UInt32>()

    /// 每 0.35 秒看一眼台上窗口的位置（只问窗口服务器，~1ms）。松开鼠标的那一刻：
    /// - 拖进了别的格子 → 两个窗口换位（也可以拖到另一块屏）
    /// - 拉了两栏中间的那条边 → 改比例，旁边的窗口跟着让
    /// - 其他（挪歪了、App 自己跑偏）→ 吸回格子
    /// released：测试用，当作刚松开鼠标
    @discardableResult
    public func settle(released force: Bool = false, now: Date = Date()) -> Bool {
        guard isActive, actions.canObserve else { return false }
        if !force {
            if CGEventSource.buttonState(.combinedSessionState, button: .left) {
                mouseWasDown = true
                // 鼠标按着的时候就已经离开格子的窗口 = 你手上正拖着的。
                // 只是点了一下、App 自己随后变宽（打开侧栏之类）不算你拖的：那样不该换位、不该改比例
                movingWhileDown.formUnion(offTarget().subtracting(offBeforePress))
                return false
            }
        }
        let released = force || mouseWasDown
        let dragged = movingWhileDown
        mouseWasDown = false
        movingWhileDown = []
        guard now.timeIntervalSince(lastOwnAction) >= settleDelay else { offBeforePress = []; return false }
        let prof = actions.profile()
        let actual = actions.frames(of: Array(onStage))
        let away = awayDisplays()
        var off = Set<UInt32>()
        defer { offBeforePress = off }
        for u in Array(stages.keys) where !away.contains(u) {
            guard let d = prof.display(uuid: u), let st = stages[u] else { continue }
            let fr = frames(st, in: d.visible)
            for (i, id) in st.slots.enumerated() where i < fr.count {
                guard let id, let f = actual[id], !stash.isStashed(id) else { continue }
                let t = fr[i]
                if Self.near(f, t, 6) { driftSince[id] = nil; snapTries[id] = nil; zoomed.remove(id); continue }
                off.insert(id)
                if f.width >= d.visible.width * 0.9 && f.height >= d.visible.height * 0.85 {
                    if zoomed.insert(id).inserted { log("临时铺满：\(id)") }
                    continue
                }
                let back = zoomed.remove(id) != nil
                let first = driftSince[id] ?? now
                driftSince[id] = first
                // 不是刚松开鼠标：可能是 App 自己在调整（或键盘挪窗口），给它一点时间稳定下来
                let byUser = force || (released && dragged.contains(id))
                if !byUser && !back && now.timeIntervalSince(first) < 1.0 { continue }
                // 吸了两次还是不肯（App 有最小高度之类）：不再每次都处理它，等你拖它或它自己回到格子
                if !byUser && !back && snapTries[id, default: 0] >= 2 { continue }
                if handleDrift(u, i, id, f, t, d, prof, byUser: byUser) { driftSince[id] = nil; return true }
            }
            // 压在下面的窗口跑偏了：你拖到别的格子 = 叠到那一格上；别的情况吸回去
            for (id, t) in stackTargets(st, in: d.visible) {
                guard let f = actual[id], !stash.isStashed(id) else { continue }
                if Self.near(f, t, 6) { driftSince[id] = nil; snapTries[id] = nil; continue }
                off.insert(id)
                let byUser = force || (released && dragged.contains(id))
                if byUser, let (to, j) = slotHit(f.center), !(to == u && stackLocate(id)?.slot == j),
                   let w = actions.windows().first(where: { $0.id == id }) {
                    unstack(id)
                    if stackOnto(w, display: to, slot: j) { return true }
                }
                let first = driftSince[id] ?? now
                driftSince[id] = first
                if !byUser && now.timeIntervalSince(first) < 1.0 { continue }
                let n = snapTries[id, default: 0]
                guard byUser || n < 2 else { continue }
                snapTries[id] = n + 1
                touch()
                actions.setFrame(id, t)
                return true
            }
        }
        return false
    }

    private var movingWhileDown = Set<UInt32>()
    /// 按下鼠标之前就已经不在格子里的（App 不肯缩、铺满着的）：不算你拖的
    private var offBeforePress = Set<UInt32>()

    /// 台上不在自己格子里的窗口
    private func offTarget() -> Set<UInt32> {
        guard Date().timeIntervalSince(lastOwnAction) >= promoteDelay else { return [] }
        let prof = actions.profile()
        let actual = actions.frames(of: Array(onStage))
        var out = Set<UInt32>()
        for (u, st) in stages {
            guard let d = prof.display(uuid: u) else { continue }
            let fr = frames(st, in: d.visible)
            for (i, id) in st.slots.enumerated() where i < fr.count {
                if let id, let f = actual[id], !Self.near(f, fr[i], 6) { out.insert(id) }
            }
            for (id, t) in stackTargets(st, in: d.visible) { if let f = actual[id], !Self.near(f, t, 6) { out.insert(id) } }
        }
        return out
    }

    /// 某个点落在哪块屏的哪一格
    public func slotHit(_ p: CGPoint) -> (String, Int)? {
        for d in actions.profile().displays where stages[d.uuid] != nil && d.frame.contains(p) {
            guard let st = stages[d.uuid] else { continue }
            let base = baseFrames(st, in: d.visible)
            if let j = base.indices.first(where: { base[$0].contains(p) }) { return (d.uuid, j) }
        }
        return nil
    }

    /// 调试：磁吸为什么没动
    public func settleDebug() -> String {
        let down = CGEventSource.buttonState(.combinedSessionState, button: .left)
        var out = "active=\(isActive) canObserve=\(actions.canObserve) down=\(down) wasDown=\(mouseWasDown) sinceOwn=\(Date().timeIntervalSince(lastOwnAction))\n"
        let actual = actions.frames(of: Array(onStage))
        for (u, st) in stages {
            let fr = slotFrames(u)
            for (i, id) in st.slots.enumerated() where i < fr.count {
                guard let id else { continue }
                out += "\(u.prefix(4)) slot\(i) \(id) actual=\(actual[id].map { "\($0)" } ?? "nil") target=\(fr[i]) stashed=\(stash.isStashed(id)) drift=\(driftSince[id].map { "\(Date().timeIntervalSince($0))" } ?? "-") tries=\(snapTries[id] ?? 0) zoomed=\(zoomed.contains(id))\n"
            }
        }
        return out
    }

    static func near(_ a: CGRect, _ b: CGRect, _ tol: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    /// byUser：刚松开鼠标（是你拖的）。不是你拖的（App 自己变宽、自己跑偏）只学最小宽度或吸回，绝不换位、不改比例
    private func handleDrift(_ u: String, _ i: Int, _ id: UInt32, _ f: CGRect, _ t: CGRect, _ d: DisplayInfo, _ prof: DisplayProfile, byUser: Bool) -> Bool {
        // 名字只在写日志时才查（以前每次都把所有 App 的窗口读一遍，窗口吸不回去时每 0.35 秒读一遍，界面跟着卡）
        var name: String { actions.windows().first { $0.id == id }.map { "\($0.appName) \($0.title.prefix(20))" } ?? "\(id)" }
        // 1. 拖进了另一个格子（同屏或别的屏）：换位
        if byUser, !t.insetBy(dx: -40, dy: -40).contains(f.center) {
            var hit: (String, Int)?
            for dd in prof.displays where stages[dd.uuid] != nil {
                for (j, g) in slotFrames(dd.uuid).enumerated() where g.contains(f.center) && !(dd.uuid == u && j == i) { hit = (dd.uuid, j) }
            }
            // 拖到另一块屏的舞台上：插进去（那块屏版式长一格），不是互换
            if let (to, _) = hit, to != u, let w = actions.windows().first(where: { $0.id == id }),
               let pl = planInsert(id, display: to, at: f.center) {
                return insert(w, plan: pl)
            }
            if let (to, j) = hit, stages[to]?.locked.contains(j) != true {
                touch(); snapshot()
                let other = stages[to]!.slots[j]
                stages[to]!.slots[j] = id
                stages[u]!.slots[i] = other
                if to != u {
                    // 整摞跟着走
                    let mine = stages[u]!.stacks.removeValue(forKey: id), theirs = other.flatMap { stages[to]!.stacks.removeValue(forKey: $0) }
                    if let mine { stages[to]!.stacks[id] = mine }
                    if let other, let theirs { stages[u]!.stacks[other] = theirs }
                }
                if let other { home[other] = u }
                home[id] = to
                if to != u {
                    onMovedAway(id, u)
                    if let other { onMovedAway(other, to) }
                }
                stages[to]!.active = j
                focusedDisplay = to
                layout(u)
                if to != u { layout(to) }
                log("拖动换位：\(name) → \(to == u ? "" : "另一块屏 ")格子 \(j)")
                onRelayout(to)
                return true
            }
            // 拖到了一块还没有舞台的屏幕：在那块屏上台，原来的格子空出来
            if let dd = prof.display(containing: f.center), dd.uuid != u, stages[dd.uuid] == nil {
                touch(); snapshot()
                let carried = stages[u]!.stacks.removeValue(forKey: id) ?? []
                stages[u]!.slots[i] = nil
                shrink(u)
                stages[dd.uuid] = DisplayStage(spec: StageSpec(.focus), slots: [id], stacks: carried.isEmpty ? [:] : [id: carried])
                home[id] = dd.uuid
                focusedDisplay = dd.uuid
                onMovedAway(id, u)
                layout(u); layout(dd.uuid)
                log("拖到另一块屏：\(name)")
                onRelayout(dd.uuid)
                return true
            }
        }
        // 2. 拉了两栏之间的那条边：改比例
        if byUser, let st = stages[u], let r = Self.ratio(afterResizing: i, of: st.spec, from: t, to: f, in: d.visible, gap: gap) {
            touch(); snapshot()
            stages[u]!.spec.ratio = r
            layout(u)
            log("拉边改比例：\(Int(r * 100))%")
            onRelayout(u)
            return true
        }
        // 3. 左上角和高度都对得上、只是更宽：App 不肯变窄（企业微信这类过一会儿自己弹回去），记住最小宽度、别的格子让位
        if f.width > t.width + 4, abs(f.minX - t.minX) <= 4, abs(f.minY - t.minY) <= 4, abs(f.height - t.height) <= 4,
           (learnedMin[id] ?? 0) < f.width - 2 {
            learnedMin[id] = f.width
            log("事后发现最小宽度 \(Int(f.width))：\(name)")
            layout(u); onRelayout(u)
            return true
        }
        // 4. 吸回格子（App 不肯就算了，最多试两次）
        let n = snapTries[id, default: 0]
        guard n < 2 else { return false }
        snapTries[id] = n + 1
        touch()
        actions.setFrame(id, t)
        log("吸回格子：\(name)")
        return true
    }

    /// 拉了某个格子的内侧边之后，新的比例（拉的是外侧边 / 整个挪了 → nil）
    public static func ratio(afterResizing i: Int, of spec: StageSpec, from t: CGRect, to f: CGRect, in rect: CGRect, gap g: CGFloat) -> Double? {
        let r = rect.insetBy(dx: g, dy: g)
        let leftFixed = abs(f.minX - t.minX) <= 8, rightFixed = abs(f.maxX - t.maxX) <= 8
        guard leftFixed != rightFixed else { return nil }
        var ratio: Double
        switch spec.layout {
        case .split, .mainStack, .quad:
            let avail = r.width - g
            let isLeft = t.midX < r.midX
            let leftW: CGFloat
            if isLeft && leftFixed { leftW = f.maxX - r.minX }
            else if !isLeft && rightFixed { leftW = f.minX - g - r.minX }
            else { return nil }
            let share = Double(leftW / avail)
            ratio = spec.mirrored ? 1 - share : share
            ratio = min(0.75, max(0.25, ratio))
        case .triple:
            let avail = r.width - 2 * g
            if i == 0 { ratio = Double(f.width / avail) }
            else if i == 1 && leftFixed { ratio = 1 - 2 * Double(f.width / avail) }
            else if i == 2 && rightFixed { ratio = 1 - 2 * Double(f.width / avail) }
            else { return nil }
            ratio = min(0.7, max(0.25, ratio))
        case .focus, .full:
            return nil
        }
        return abs(ratio - spec.ratio) > 0.02 ? ratio : nil
    }

    // MARK: 撤销 / 归位

    private var history: [[String: DisplayStage]] = []
    private func snapshot() {
        if history.last != stages { history.append(stages) }
        if history.count > 30 { history.removeFirst(history.count - 30) }
    }
    public var canUndo: Bool { history.contains { $0 != stages } }

    /// 回到上一步：哪个格子放谁、什么版式，全部恢复
    @discardableResult
    public func undo() -> Bool {
        guard isActive else { return false }
        var prev: [String: DisplayStage]?
        while let p = history.popLast() { if p != stages { prev = p; break } }
        guard var prev else { return false }
        touch()
        let live = actions.windows()
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let prof = actions.profile()
        for u in Array(prev.keys) {
            guard prof.display(uuid: u) != nil else { prev[u] = stages[u]; continue }
            for (i, id) in prev[u]!.slots.enumerated() {
                guard let id else { continue }
                if let w = byID[id] { bringBack(w); home[id] = u } else { prev[u]!.slots[i] = nil }
            }
        }
        let want = Set(prev.values.flatMap(\.allWindows))
        let cur = onStage
        for (u, st) in prev { stages[u] = st }
        for id in cur where !want.contains(id) { hide(id) }
        layoutAll()
        if let u = focusedDisplay ?? currentDisplay(), let st = stages[u], let id = st.slots[st.active] ?? st.windows.first { actions.focus(id) }
        log("撤销：回到上一步")
        return true
    }

    /// 一键归位：每个窗口回到自己的格子、跑出来的后台窗口藏回去、关掉的让出格子
    public func heal() {
        guard isActive, actions.canObserve else { return }
        touch()
        driftSince.removeAll(); snapTries.removeAll(); zoomed.removeAll()
        markSpaces()
        let live = actions.windows()
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for u in Array(stages.keys) {
            for (i, id) in stages[u]!.slots.enumerated() {
                guard let id else { continue }
                if let w = byID[id] { if w.isMinimized { actions.setMinimized(id, false) } }
                else if !actions.exists(id) { stages[u]!.slots[i] = nil }
            }
        }
        sweep(live)
        stash.enforce(live: actions.windows(), except: onStage)
        layoutAll()
        if let u = currentDisplay(), let st = stages[u], let id = st.slots[st.active] ?? st.windows.first { actions.focus(id) }
        log("一键归位")
    }

    // MARK: 内部

    private func touch() { lastOwnAction = Date() }

    private func targetDisplay(for w: WindowInfo) -> String? {
        let prof = actions.profile()
        // 有「家」的窗口回自己的屏幕：笔记本上的微信不会因为你刚在大屏上操作就跑到大屏
        if let h = home[w.id], prof.display(uuid: h) != nil { return h }
        if let o = originals[w.id], let u = prof.display(containing: o.center)?.uuid { return u }
        // 看得见的窗口（刚新建的）就在它所在的屏幕上台
        if !stash.isStashed(w.id), let u = w.displayUUID, prof.display(uuid: u) != nil, !w.isMinimized,
           stages[u] != nil || focusedDisplay == nil { return u }
        return currentDisplay()
    }

    /// 从后台 / 最小化里拿回来
    private func bringBack(_ w: WindowInfo) {
        if let e = stash.release(w.id) { originals[w.id] = originals[w.id] ?? e.originalFrame }
        else { originals[w.id] = originals[w.id] ?? w.frame }
        if w.isMinimized { actions.setMinimized(w.id, false) }
    }

    private func hide(_ id: UInt32) {
        guard let w = actions.windows().first(where: { $0.id == id }) else { return }
        let o = originals[w.id] ?? stash.entry(w.id)?.originalFrame ?? w.frame
        originals[w.id] = o
        stash.stash(w, original: o, byStage: true, near: home[w.id])
    }

    /// 已上台屏幕上的其他普通窗口退到后台
    @discardableResult
    private func sweep(_ live: [WindowInfo]) -> Set<UInt32> {
        if !seenBaseline { noteSeen(live) }
        var hidden = Set<UInt32>()
        let stagedDisplays = Set(stages.keys).subtracting(awayDisplays())
        let on = onStage
        for w in live where stageable(w) && !w.isMinimized && !on.contains(w.id) && !stash.isStashed(w.id) {
            guard let u = w.displayUUID, stagedDisplays.contains(u) else { continue }
            // 附属窗口：它的 App 还在台上就浮着；App 下台了就跟着退到后台（不再算附属）
            if companions.contains(w.id) || adoptCompanion(w, live: live) {
                if live.contains(where: { on.contains($0.id) && $0.bundleID == w.bundleID }) { continue }
                companions.remove(w.id)
            }
            if originals[w.id] == nil { originals[w.id] = w.frame }
            if home[w.id] == nil { home[w.id] = u }
            stash.stash(w, original: originals[w.id]!, byStage: true, near: home[w.id])
            hidden.insert(w.id)
        }
        return hidden
    }

    private func layoutAll() { for u in stages.keys { layout(u) } }

    /// 插拔屏：拔掉的屏上的舞台先记着（它的窗口被系统挪到剩下的屏上，会退到后台，场景随时能在剩下的屏上摆出来）；
    /// 插回来时，那块屏上原来的舞台自动恢复
    public func displaysChanged() {
        guard isActive, actions.canObserve else { return }
        touch()
        let prof = actions.profile()
        for u in Array(stages.keys) where prof.display(uuid: u) == nil {
            parked[u] = stages.removeValue(forKey: u)
            spaceOf[u] = nil
            log("屏幕拔掉了：先记住它的舞台")
        }
        let live = actions.windows()
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (u, st) in parked where prof.display(uuid: u) != nil {
            parked[u] = nil
            var slots = st.slots
            for (i, id) in slots.enumerated() {
                guard let id else { continue }
                if let w = byID[id], w.axAvailable, !isOnStage(id) { bringBack(w); home[id] = u } else { slots[i] = nil }
            }
            var stacks: [UInt32: [UInt32]] = [:]
            for (top, m) in st.stacks where slots.contains(top) {
                let ok = m.filter { id in if let w = byID[id], w.axAvailable, !isOnStage(id) { bringBack(w); home[id] = u; return true }; return false }
                if !ok.isEmpty { stacks[top] = ok }
            }
            stages[u] = DisplayStage(spec: st.spec, slots: slots, active: st.active, locked: st.locked, stacks: stacks)
            log("屏幕插回来了：恢复它的舞台")
        }
        markSpaces()
        sweep(actions.windows())
        layoutAll()
    }

    /// 屏幕可用区域变了（Dock 变长 / 隐藏、菜单栏变化）但屏幕没换：原地按新区域重排
    public func relayout() {
        guard isActive, actions.canObserve else { return }
        touch()
        layoutAll()
    }

    private func layout(_ u: String) {
        tidyStacks(u)
        recordSlots(u)
        guard let st = stages[u], let d = actions.profile().display(uuid: u) else { return }
        for (id, f) in stackTargets(st, in: d.visible) { actions.setFrame(id, f); everStaged.insert(id) }
        if spaceOf[u] == nil, let sp = actions.displaySpaces()[u] { spaceOf[u] = sp }
        let fr = frames(st, in: d.visible)
        let ids = st.windows
        let before = actions.frames(of: ids)
        for (i, id) in st.slots.enumerated() where i < fr.count {
            if let id { actions.setFrame(id, fr[i]); everStaged.insert(id); snapTries[id] = nil }
        }
        // Chrome、Electron 类 App 改尺寸是异步的，有的还有最小宽度（微信、钉钉…）。
        // 等一下读回真实尺寸：没到位的重试一次；还是更宽 = 最小宽度，记下来、让别的格子让出空间
        verify(u, before: before, attempt: 0)
    }

    private var verifyToken: [String: Int] = [:]

    private func verify(_ u: String, before: [UInt32: CGRect], attempt: Int) {
        verifyToken[u, default: 0] += 1
        let token = verifyToken[u]!
        let run = { [weak self] in
            guard let self, self.isActive, token == self.verifyToken[u], let st = self.stages[u],
                  let d = self.actions.profile().display(uuid: u) else { return }
            let fr = self.frames(st, in: d.visible)
            let actual = self.actions.frames(of: st.windows)
            var off: [(Int, UInt32)] = []
            for (i, id) in st.slots.enumerated() where i < fr.count {
                guard let id, let f = actual[id] else { continue }
                let t = fr[i]
                if abs(f.minX - t.minX) > 4 || abs(f.minY - t.minY) > 4 || abs(f.width - t.width) > 4 || abs(f.height - t.height) > 4 {
                    off.append((i, id))
                }
            }
            guard !off.isEmpty else { return }
            if attempt == 0 {
                for (i, id) in off { self.actions.setFrame(id, fr[i]) }
                self.verify(u, before: before, attempt: 1)
                return
            }
            guard attempt == 1 else { return }
            var relayout = false
            for (i, id) in off {
                guard let f = actual[id] else { continue }
                let t = fr[i]
                // 注意：不再凭「重试后尺寸没变」就判定改不了大小、把窗口请下台——Chrome / Electron 改尺寸是异步的，
                // 慢一点就会被误杀（Claude 就被这样踢出去过）。真改不了大小的窗口在读 AX 时就知道（fixedSize）
                if f.width > t.width + 4, abs(f.minX - t.minX) <= 4, (self.learnedMin[id] ?? 0) < f.width - 2 {
                    self.learnedMin[id] = f.width
                    self.log("最小宽度 \(Int(f.width))：\(id)")
                    relayout = true
                }
            }
            if relayout {
                let st2 = self.stages[u]!
                let fr2 = self.frames(st2, in: d.visible)
                for (i, id) in st2.slots.enumerated() where i < fr2.count { if let id { self.actions.setFrame(id, fr2[i]) } }
                self.verify(u, before: before, attempt: 2)
                self.onRelayout(u)
            }
        }
        if verifyDelay <= 0 { run() } else { DispatchQueue.main.asyncAfter(deadline: .now() + verifyDelay * Double(attempt + 1), execute: run) }
    }

    /// 校验后格子变了（最小宽度、固定尺寸）：界面刷新
    public var onRelayout: (String) -> Void = { _ in }
}

// MARK: - 同一个 App 的多个窗口怎么区分

public enum WindowLabeler {
    /// 同一个 App 开了多个窗口时，给每个窗口一句能区分的说明，如「主窗口 · 左侧」「小窗 · 右上」
    public static func labels(_ windows: [WindowInfo], profile: DisplayProfile) -> [UInt32: String] {
        var out: [UInt32: String] = [:]
        let groups = Dictionary(grouping: windows, by: \.bundleID).filter { $0.value.count > 1 }
        for (_, ws) in groups {
            let area: (WindowInfo) -> CGFloat = { $0.frame.width * $0.frame.height }
            let sorted = ws.sorted { area($0) > area($1) }
            let biggest = area(sorted[0])
            let second = sorted.count > 1 ? area(sorted[1]) : 0
            for w in ws {
                var parts: [String] = []
                if w.id == sorted[0].id && biggest > second * 1.3 { parts.append("主窗口") }
                else if area(w) < biggest * 0.45 { parts.append("小窗") }
                if w.isMinimized { parts.append("已最小化") }
                else if !w.axAvailable { parts.append("在其他桌面") }
                else if let d = profile.display(uuid: w.displayUUID) {
                    parts.append(position(w.frame, in: d.visible))
                    if profile.displays.count > 1 { parts.append(d.isBuiltin ? "笔记本屏" : d.name) }
                }
                parts.append("\(Int(w.frame.width))×\(Int(w.frame.height))")
                out[w.id] = parts.joined(separator: " · ")
            }
        }
        return out
    }

    static func position(_ f: CGRect, in v: CGRect) -> String {
        guard v.width > 0, v.height > 0 else { return "" }
        let x = (f.midX - v.minX) / v.width, y = (f.midY - v.minY) / v.height
        if f.width > v.width * 0.9 && f.height > v.height * 0.85 { return "铺满" }
        let h = x < 0.36 ? "左" : x > 0.64 ? "右" : ""
        let vv = y < 0.36 ? "上" : y > 0.64 ? "下" : ""
        if h.isEmpty && vv.isEmpty { return "居中" }
        if vv.isEmpty { return h + "侧" }
        if h.isEmpty { return vv + "方" }
        return h + vv
    }
}
