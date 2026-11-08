import CoreGraphics
import Foundation
import WeftAI
import WeftCore

// 简易断言框架（CommandLineTools 无 XCTest）
var failures = 0, passes = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, line: Int = #line) {
    if cond() { passes += 1 } else { failures += 1; print("✗ [L\(line)] \(msg)") }
}

// MARK: - 假窗口系统

final class FakeWindows: WindowActions {
    var wins: [WindowInfo]
    var prof: DisplayProfile
    var log: [String] = []
    /// 模拟 App 的最小宽度
    var minWidth: [UInt32: CGFloat] = [:]
    init(_ w: [WindowInfo], _ p: DisplayProfile) { wins = w; prof = p }
    /// 模拟锁屏：AX 看不到任何窗口，但窗口都还在
    var locked = false
    func windows() -> [WindowInfo] { locked ? [] : wins }
    func exists(_ id: UInt32) -> Bool { wins.contains { $0.id == id } }
    var canObserve: Bool { !locked }
    func profile() -> DisplayProfile { prof }
    func focus(_ id: UInt32) -> Bool { log.append("focus \(id)"); return wins.contains { $0.id == id } }
    func setFrame(_ id: UInt32, _ f: CGRect) -> Bool {
        guard let i = wins.firstIndex(where: { $0.id == id }) else { return false }
        var f = f
        if let m = minWidth[id], f.width < m { f.size.width = m }
        wins[i].frame = f
        wins[i].displayUUID = prof.display(containing: f.center)?.uuid
        log.append("frame \(id) \(f)")
        return true
    }
    /// 模拟系统桌面：每块屏现在显示的桌面
    var spaces: [String: Int] = [:]
    func displaySpaces() -> [String: Int] { spaces }
    func setMinimized(_ id: UInt32, _ m: Bool) -> Bool {
        guard let i = wins.firstIndex(where: { $0.id == id }) else { return false }
        if wins[i].isMinimized != m { log.append("min \(id) \(m)") }
        wins[i].isMinimized = m
        return true
    }
}

let laptop = DisplayInfo(id: 1, uuid: "LAPTOP", name: "内建显示器",
                         frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                         visible: CGRect(x: 0, y: 33, width: 1512, height: 949), isMain: true, isBuiltin: true)
let external = DisplayInfo(id: 2, uuid: "DELL", name: "DELL U2723QE",
                           frame: CGRect(x: 1512, y: -400, width: 2560, height: 1440),
                           visible: CGRect(x: 1512, y: -375, width: 2560, height: 1415), isMain: false, isBuiltin: false)
let both = DisplayProfile(displays: [laptop, external])
let solo = DisplayProfile(displays: [laptop])

func win(_ id: UInt32, _ app: String, _ bundle: String, _ title: String, _ f: CGRect, _ p: DisplayProfile, z: Int = 0) -> WindowInfo {
    WindowInfo(id: id, pid: Int32(id), bundleID: bundle, appName: app, title: title, frame: f,
               displayUUID: p.display(containing: f.center)?.uuid, zIndex: z)
}

func sampleWindows(_ p: DisplayProfile) -> [WindowInfo] {
    [
        win(11, "Google Chrome", "com.google.Chrome", "Pull requests · weft/weft - GitHub", CGRect(x: 1512, y: -375, width: 1280, height: 1415), p, z: 0),
        win(12, "Google Chrome", "com.google.Chrome", "澜起科技 2026Q3 财报 - 东方财富", CGRect(x: 2792, y: -375, width: 1280, height: 1415), p, z: 3),
        win(13, "Google Chrome", "com.google.Chrome", "Gmail - 收件箱", CGRect(x: 0, y: 33, width: 1512, height: 949), p, z: 5),
        win(21, "微信", "com.tencent.xinWeChat", "微信", CGRect(x: 100, y: 100, width: 900, height: 700), p, z: 1),
        win(31, "iTerm2", "com.googlecode.iterm2", "~/Mine/si/projects/weft — zsh", CGRect(x: 0, y: 33, width: 756, height: 949), p, z: 2),
        win(41, "飞书", "com.electron.lark", "飞书 - 产品周会", CGRect(x: 756, y: 33, width: 756, height: 949), p, z: 4),
    ]
}

// MARK: - 拼音 / 模糊搜索

let py = Pinyin.convert("微信")
check(py.full == "weixin", "微信 全拼 = weixin，实际 \(py.full)")
check(py.initials == "wx", "微信 首字母 = wx，实际 \(py.initials)")
check(Pinyin.convert("飞书 - 产品周会").initials == "fscpzh", "混合文本首字母：\(Pinyin.convert("飞书 - 产品周会").initials)")

let ws = sampleWindows(both)
func top(_ q: String) -> UInt32? { FuzzyMatcher.rank(ws, query: q).first?.id }
check(top("wx") == 21, "wx → 微信")
check(top("weixin") == 21, "weixin → 微信")
check(top("gh pr") == 11, "gh pr → GitHub PR 窗口，实际 \(String(describing: top("gh pr")))")
check(top("lq") == 12, "lq（澜起）→ 财报窗口，实际 \(String(describing: top("lq")))")
check(top("gmail") == 13, "gmail → Gmail")
check(top("term weft") == 31, "term weft → iTerm")
check(top("zhouhui") == 41, "zhouhui → 飞书周会")
check(FuzzyMatcher.rank(ws, query: "zzzzqqq").isEmpty, "无匹配返回空")
check(FuzzyMatcher.rank(ws, query: "").map(\.id) == [11, 21, 31, 12, 41, 13], "空查询按 z 序")

// MARK: - 窗口身份匹配

check(WindowMatcher.similarity("Pull requests · weft - GitHub", "Pull requests · weft - GitHub") == 1, "相同标题相似度 1")
check(WindowMatcher.similarity("Issue #12 · weft - GitHub", "Issue #13 · weft - GitHub") > 0.8, "相近标题相似度高")
let saved = [
    SavedWindow(bundleID: "com.google.Chrome", appName: "Chrome", title: "澜起科技 2026Q3 财报 - 东方财富", displayUUID: "DELL", rel: .zero, isMinimized: false),
    SavedWindow(bundleID: "com.google.Chrome", appName: "Chrome", title: "Pull requests · weft/weft - GitHub", displayUUID: "DELL", rel: .zero, isMinimized: false),
]
let pairs = WindowMatcher.match(saved: saved, live: ws)
check(pairs.count == 2, "两个 Chrome 窗口都能配对")
check(pairs.first(where: { $0.0.title.hasPrefix("澜起") })?.1.id == 12, "按标题配对到正确的 Chrome 窗口")

// MARK: - 布局：保存 → 拔屏 → 降级 → 插回 → 恢复

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("weft-selftest-\(UUID().uuidString)")
let store = Store(dir: tmp)
let fake = FakeWindows(sampleWindows(both), both)
let engine = LayoutEngine(actions: fake, store: store)
engine.log = { _ in }
let layout = engine.saveManual()
check(layout.windows.count == 6, "保存 6 个窗口")
let ghRel = layout.windows.first { $0.title.hasPrefix("Pull") }!.rel
check(abs(ghRel.minX) < 0.001 && abs(ghRel.width - 0.5) < 0.001, "相对坐标：GitHub 窗口在外接屏左半边 \(ghRel)")

// 拔掉外接屏：macOS 会把外接屏窗口堆到主屏左上角
fake.prof = solo
for i in fake.wins.indices where fake.wins[i].displayUUID == "DELL" {
    fake.wins[i].frame = CGRect(x: 0, y: 33, width: 1280, height: 949)
    fake.wins[i].displayUUID = "LAPTOP"
}
engine.displaysChanged()
let gh = fake.wins.first { $0.id == 11 }!, cj = fake.wins.first { $0.id == 12 }!
check(gh.frame == CGRect(x: 0, y: 33, width: 756, height: 949), "降级：GitHub 窗口按比例放到笔记本左半 \(gh.frame)")
check(cj.frame == CGRect(x: 756, y: 33, width: 756, height: 949), "降级：财报窗口按比例放到笔记本右半 \(cj.frame)")
check(engine.undo.canUndo, "降级操作可撤销")

// 插回外接屏：恢复手动保存的布局
fake.prof = both
engine.displaysChanged()
check(fake.wins.first { $0.id == 11 }!.frame == CGRect(x: 1512, y: -375, width: 1280, height: 1415), "插回后 GitHub 窗口回到外接屏")
check(fake.wins.first { $0.id == 12 }!.frame == CGRect(x: 2792, y: -375, width: 1280, height: 1415), "插回后财报窗口回到外接屏")

// 撤销
_ = engine.undoLast()
check(fake.wins.first { $0.id == 11 }!.frame == CGRect(x: 0, y: 33, width: 756, height: 949), "撤销回到上一步")

// 持久化
let reloaded = LayoutEngine(actions: fake, store: store)
check(reloaded.db.manual[both.fingerprint]?.windows.count == 6, "布局持久化到磁盘")

// 屏幕外窗口拉回
let lost = [win(99, "X", "x", "x", CGRect(x: 3000, y: 200, width: 800, height: 600), solo)]
let rescue = LayoutPlanner.rescueOffscreen(windows: lost, profile: solo)
check(rescue.count == 1 && laptop.visible.contains(rescue[0].frame), "屏幕外窗口被拉回主屏 \(rescue.first?.frame ?? .zero)")

// MARK: - 区域 / 平铺

check(Region.tile(count: 3, arrangement: "columns").map(\.minX) == [0, 1.0 / 3, 2.0 / 3], "三列平铺")
check(Region.tile(count: 4, arrangement: "grid").count == 4 && Region.tile(count: 4, arrangement: "grid")[3] == CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), "2x2 网格")

// MARK: - AI 工具执行（不调用模型）

let fake2 = FakeWindows(sampleWindows(both), both)
let agent = WindowAgent(config: .unconfigured, actions: fake2)
check(agent.execute(name: "place_window", arguments: #"{"id":21,"display":"main","region":"right-half"}"#) == "ok", "place_window 执行")
check(fake2.wins.first { $0.id == 21 }!.frame == CGRect(x: 756, y: 33, width: 756, height: 949), "微信在主屏右半")
check(agent.execute(name: "tile_windows", arguments: #"{"ids":[11,12,13],"display":"2","arrangement":"columns"}"#) == "ok", "tile_windows 执行")
check(fake2.wins.first { $0.id == 13 }!.frame.minX > 3000, "Gmail 被平铺到外接屏第三列")
check(agent.execute(name: "bogus", arguments: "{}").hasPrefix("error"), "未知工具报错")
check(agent.snapshotJSON().contains("(已隐藏)"), "微信标题被脱敏")
check(!agent.snapshotJSON().contains("产品周会"), "飞书标题被脱敏")

// MARK: - 习惯学习

let habitStore = Store(dir: tmp.appendingPathComponent("h"))
let habits = HabitTracker(store: habitStore)
let hw = sampleWindows(both)
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
// 模拟：GitHub ↔ iTerm 来回切了 6 次，偶尔看一下微信
var clock = t0
for i in 0..<6 {
    habits.observe(focused: hw[0], now: clock); clock += 120
    habits.observe(focused: hw[4], now: clock); clock += 90
    if i == 3 { habits.observe(focused: hw[3], now: clock); clock += 30 }
}
habits.observe(focused: hw[0], now: clock)
let pred = habits.predict(hw, now: clock + 5)
let best = pred.max { $0.value < $1.value }?.key
check(best == 31, "在 GitHub 上时，预测下一个最可能是 iTerm（实际 \(String(describing: best))）")
check((pred[11] ?? 0) < 0, "当前窗口不会被推荐")
check(habits.mru.prefix(2) == [11, 31], "MRU 顺序正确 \(habits.mru.prefix(3))")
let co = habits.coUsage(hw)
check(co.first.map { Set([$0.0, $0.1]) } == [11, 31], "共用最多的是 GitHub + iTerm")
check(HabitTracker.normalize("(3) 微信 - Google Chrome") == "微信", "标题归一化去掉未读数和浏览器后缀")
habits.persistIfNeeded()
check(HabitTracker(store: habitStore).db.windows.count == 3, "习惯持久化")

// MARK: - 事情 & 停靠

let members = [ContextResolver.member(hw[0]), ContextResolver.member(hw[4])]
var renamed = hw
renamed[0].id = 9011; renamed[0].title = "Pull requests · weft/weft - GitHub"   // 重启后 ID 变了
renamed[4].id = 9031
check(ContextResolver.resolve(members, in: renamed).map(\.id) == [9011, 9031], "重启后按标题找回事情里的窗口")

let fake3 = FakeWindows(sampleWindows(both), both)
let stashMgr = StashManager(actions: fake3, store: Store(dir: tmp.appendingPathComponent("s")))
let orig = fake3.wins[3].frame
stashMgr.stash(fake3.wins[3])
let parked = fake3.wins[3].frame.insetBy(dx: 1, dy: 1)
check(!both.displays.contains { $0.frame.intersects(parked) }, "停靠后窗口挪到屏幕外（只留 1px） \(fake3.wins[3].frame)")
check(abs(parked.maxX - 0) < 2 || abs(parked.minX - 1512) < 2, "停靠贴着自己那块屏幕（笔记本）")
// 外接屏在上方（你的真实布局）：贴笔记本右下角
let above = DisplayProfile(displays: [laptop, DisplayInfo(id: 5, uuid: "UP", name: "DELL", frame: CGRect(x: -473, y: -1440, width: 2560, height: 1440),
                                                          visible: CGRect(x: -473, y: -1410, width: 2560, height: 1410), isMain: false, isBuiltin: false)])
let spot = StashManager.parkingSpot(for: CGSize(width: 900, height: 700), home: laptop, in: above)
check(spot == CGPoint(x: 1511, y: 981), "外接屏在上方时停在笔记本右下角 \(spot)")
let spotUp = StashManager.parkingSpot(for: CGSize(width: 900, height: 700), home: above.displays[1], in: above)
check(!above.displays.contains { $0.frame.intersects(CGRect(origin: spotUp, size: CGSize(width: 900, height: 700)).insetBy(dx: 1, dy: 1)) }, "外接屏的窗口停在外接屏外侧 \(spotUp)")
// 最小宽度：微信缩不到 600 以下，左右分栏时让它宽一点
let mf = StageGeometry.frames(StageSpec(.split, ratio: 0.3), in: laptop.visible, gap: 10, minWidths: [0: 700])
check(mf[0].width == 700 && mf[1].minX == mf[0].maxX + 10 && mf[1].maxX == laptop.visible.maxX - 10, "最小宽度重分 \(mf)")
let tf = StageGeometry.frames(StageSpec(.triple), in: laptop.visible, gap: 10)
check(abs(tf[1].maxX + 10 - tf[0].minX) <= 1 && abs(tf[0].maxX + 10 - tf[2].minX) <= 1, "三栏左中右相接 \(tf)")
check(stashMgr.isStashed(21), "停靠记录")
stashMgr.unstash(21)
check(fake3.wins[3].frame == orig, "取消停靠回到原位")
stashMgr.stash(fake3.wins[3]); stashMgr.restoreAll()
check(fake3.wins[3].frame == orig && stashMgr.entries.isEmpty, "退出时全部放回")

// MARK: - 舞台模式

let gFocus = StageGeometry.frames(StageSpec(.focus), in: laptop.visible, gap: 10)
check(gFocus.count == 1 && gFocus[0].width == 1300 && abs(gFocus[0].midX - 756) < 1, "笔记本屏专注版式居中 \(gFocus)")
let gSplit = StageGeometry.frames(StageSpec(.split, ratio: 0.6), in: laptop.visible, gap: 10)
check(gSplit[0].minX == 10 && gSplit[1].maxX == 1502 && gSplit[0].width > gSplit[1].width, "左右 6:4 \(gSplit)")
let gMir = StageGeometry.frames(StageSpec(.split, ratio: 0.6, mirrored: true), in: laptop.visible, gap: 10)
check(gMir[0].minX > gMir[1].minX && gMir[0].width > gMir[1].width, "主窗口放右边")
let gStack = StageGeometry.frames(StageSpec(.mainStack), in: external.visible, gap: 10)
check(gStack.count == 3 && gStack[1].minX == gStack[2].minX && gStack[1].maxY < gStack[2].minY, "一主两辅：右侧上下叠")
let gTri = StageGeometry.frames(StageSpec(.triple), in: external.visible, gap: 10)
check(gTri[1].maxX < gTri[0].minX && gTri[0].maxX < gTri[2].minX, "三栏：0 号在中间")
check(StageGeometry.effective(StageSpec(.triple), filled: 2).layout == .split, "AI 排布：三栏只给两个窗口 → 左右")
let gQuad = StageGeometry.frames(StageSpec(.quad), in: external.visible, gap: 10)
check(gQuad.count == 4 && gQuad[0].minX == gQuad[2].minX && gQuad[0].minY == gQuad[1].minY && gQuad[3].minX == gQuad[1].minX && gQuad[3].minY == gQuad[2].minY,
      "四宫格：0 左上 1 右上 2 左下 3 右下 \(gQuad)")

let fake4 = FakeWindows(sampleWindows(both), both)
let stash4 = StashManager(actions: fake4, store: Store(dir: tmp.appendingPathComponent("stage")))
let stage = StageManager(actions: fake4, stash: stash4); stage.verifyDelay = 0
stage.promoteDelay = 0
let preStage = Dictionary(fake4.wins.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
func fr(_ id: UInt32) -> CGRect { fake4.wins.first { $0.id == id }!.frame }
func ws(_ id: UInt32) -> WindowInfo { fake4.wins.first { $0.id == id }! }
stage.enter(focused: 31)
check(stage.stages["LAPTOP"]?.slots == [31] && stage.stages["DELL"]?.slots == [11], "进入舞台：每块屏一个窗口 \(stage.stages)")
check(Set(stash4.entries.map(\.windowID)) == [21, 41, 13, 12] && stash4.entries.allSatisfy { $0.byStage == true }, "其余窗口退到后台")
check(fr(31).width == 1300, "当前窗口按专注版式摆好 \(fr(31))")
stage.present(ws(21))
check(stage.stages["LAPTOP"]?.slots == [21] && stash4.isStashed(31) && !stash4.isStashed(21), "换上微信，iTerm 下台")
check(laptop.visible.contains(fr(21)), "微信在笔记本屏上 \(fr(21))")
// 换成左右但不给候选：第二个格子空着（不再自动退化成专注）
stage.setSpec(StageSpec(.split), display: "LAPTOP")
let half = StageGeometry.frames(StageSpec(.split), in: laptop.visible, gap: 10)
check(stage.stages["LAPTOP"]?.slots == [21, nil] && fr(21) == half[0], "改成左右：右边格子空着，微信只占左半 \(fr(21))")
stage.present(ws(31), on: "LAPTOP", slot: 1)
check(stage.stages["LAPTOP"]?.slots == [21, 31] && !stash4.isStashed(31) && fr(31) == half[1], "在空格子里选了 iTerm")
stage.swapMain(display: "LAPTOP")
check(stage.stages["LAPTOP"]?.slots == [31, 21] && fr(31).minX < fr(21).minX, "主副互换")
check(stage.onFocus(41) && stage.stages["LAPTOP"]?.slots == [41, 21] && stash4.isStashed(31), "⌘Tab 到飞书：换进当前在用的格子")
check(!stage.onFocus(21) && stage.stages["LAPTOP"]?.active == 1, "切到台上的窗口：只记录在用的格子")
// 锁住右边：⌘Tab 来的窗口换左边
stage.toggleLock(display: "LAPTOP", slot: 1)
check(stage.onFocus(31) && stage.stages["LAPTOP"]?.slots == [31, 21], "右边锁住了：iTerm 换掉左边的飞书，微信不动")
stage.toggleLock(display: "LAPTOP", slot: 1)
// 有空格子先填空格子
stage.clear(display: "LAPTOP", slot: 1)
check(stage.stages["LAPTOP"]?.slots == [31, nil] && stash4.isStashed(21), "清空右边格子")
check(stage.onFocus(41) && stage.stages["LAPTOP"]?.slots == [31, 41], "有空格子时，切来的窗口先填空格子")
// 已在台上的窗口被放进另一个格子：两格互换
stage.present(ws(31), on: "LAPTOP", slot: 1)
check(stage.stages["LAPTOP"]?.slots == [41, 31], "把左边的窗口放进右边：两格互换")
fake4.wins.removeAll { $0.id == 41 }
stage.reconcile(mru: [])
check(stage.stages["LAPTOP"]?.slots == [nil, 31] && fr(31) == half[1], "关掉一个窗口：格子空出来，版式不变 \(fr(31))")
stage.present(ws(12), on: "DELL")
check(stage.stages["DELL"]?.slots == [12] && stash4.isStashed(11), "外接屏换窗口")
// 换到四宫格再换回专注：窗口按顺序留下，多出来的退到后台
stage.setSpec(StageSpec(.quad), display: "DELL", fill: [ws(11), ws(13)])
check(stage.stages["DELL"]?.slots == [12, 11, 13, nil], "四宫格：补了两个，剩一格空着 \(stage.stages["DELL"]!.slots)")
stage.setSpec(StageSpec(.focus), display: "DELL")
check(stage.stages["DELL"]?.slots == [12] && stash4.isStashed(11) && stash4.isStashed(13), "换回专注：只留第一个")
stage.exit()
check(stash4.entries.isEmpty && !stage.isActive, "退出舞台：后台清空")
check(fr(13) == preStage[13] && fr(11) == preStage[11], "后台窗口回到进入舞台前的位置")

// AI 场景
let fake5 = FakeWindows(sampleWindows(both), both)
let stage5 = StageManager(actions: fake5, stash: StashManager(actions: fake5, store: Store(dir: tmp.appendingPathComponent("stage5")))); stage5.verifyDelay = 0
stage5.apply(scene: [("DELL", StageSpec(.split, ratio: 0.6), [11, 31]), ("LAPTOP", StageSpec(.focus), [21])])
check(stage5.isActive && stage5.stages["DELL"]?.slots == [11, 31] && stage5.stages["LAPTOP"]?.slots == [21], "应用 AI 场景 \(stage5.stages)")
check(external.visible.contains(fake5.wins.first { $0.id == 31 }!.frame), "iTerm 被搬到外接屏")

// 多屏：每个窗口回自己的屏幕，各屏互不干扰
check(stage5.currentDisplay() == "DELL", "刚操作的是外接屏")
stage5.present(fake5.wins.first { $0.id == 41 }!)
check(stage5.stages["LAPTOP"]?.slots.contains(41) == true && stage5.stages["DELL"]?.slots == [11, 31],
      "飞书的家在笔记本：即使刚在外接屏操作，也回笔记本上台，不打扰外接屏 \(stage5.stages)")
stage5.pinnedDisplay = "DELL"
stage5.present(fake5.wins.first { $0.id == 13 }!, on: stage5.currentDisplay())
check(stage5.stages["DELL"]?.slots.contains(13) == true && stage5.homeDisplay(13) == "DELL", "在外接屏的面板里明确「放到这里」：搬过去并以后住在外接屏")
stage5.pinnedDisplay = nil
// 用户把笔记本上的飞书拖进外接屏的左格子：两个窗口换位
stage5.promoteDelay = 0
let dellLeft = stage5.slotFrames("DELL")[0]
let leftWas = stage5.stages["DELL"]!.slots[0]!
let w41 = fake5.wins.firstIndex { $0.id == 41 }!
fake5.wins[w41].frame = CGRect(x: dellLeft.midX - 450, y: dellLeft.midY - 350, width: 900, height: 700)
fake5.wins[w41].displayUUID = "DELL"
stage5.settleDelay = 0
stage5.settle(released: true)
check(stage5.stages["DELL"]?.slots[0] == 41 && stage5.stages["LAPTOP"]?.slots.contains(leftWas) == true && stage5.homeDisplay(41) == "DELL",
      "拖进别的格子：两个窗口换位 \(stage5.stages)")
check(fake5.wins[w41].frame == stage5.slotFrames("DELL")[0], "拖过去的窗口贴合格子")

// App 自己把后台窗口拉回屏幕（App Store 这类）：对账时再藏一次，屡藏屡回就最小化
do {
    let f6 = FakeWindows(sampleWindows(solo), solo)
    let sm6 = StashManager(actions: f6, store: Store(dir: tmp.appendingPathComponent("stage6")))
    let st6 = StageManager(actions: f6, stash: sm6); st6.verifyDelay = 0; st6.promoteDelay = 0
    st6.enter(focused: 13)
    let hidden = sm6.entries.first!.windowID
    func pullBack() { let i = f6.wins.firstIndex { $0.id == hidden }!; f6.wins[i].frame = CGRect(x: 200, y: 100, width: 900, height: 700); f6.wins[i].zIndex = 50 }
    pullBack()
    st6.reconcile(mru: [])
    check(sm6.isParked(f6.wins.first { $0.id == hidden }!), "被拉回屏幕的后台窗口：重新藏好")
    pullBack(); st6.reconcile(mru: [])
    pullBack(); st6.reconcile(mru: [])
    check(f6.wins.first { $0.id == hidden }!.isMinimized && sm6.entry(hidden)?.viaMinimize == true, "屡藏屡回：改用最小化")
    st6.setSpec(StageSpec(.split), fill: f6.wins)
    st6.exit()
    check(!f6.wins.contains { $0.isMinimized }, "退出舞台：最小化藏起来的也还原")
    // 换版式时，记录里「藏着」但其实在屏幕上的窗口也会被藏好
    st6.enter(focused: 13)
    st6.setSpec(StageSpec(.split), fill: f6.wins)
    let side = st6.stages["LAPTOP"]!.slots[1]!
    let si = f6.wins.firstIndex { $0.id == side }!
    st6.setSpec(StageSpec(.focus))
    f6.wins[si].frame = CGRect(x: 300, y: 100, width: 900, height: 700)   // App 自己跳回来
    st6.setSpec(StageSpec(.split), fill: [])
    st6.setSpec(StageSpec(.focus))
    check(sm6.isParked(f6.wins[si]), "切回专注：之前跳回来的窗口被重新藏好")
    st6.exit()
}

// 副位上的宽窗口（最小宽度 1000）：记住最小宽度、按它重新分配，不自动换人（候选里标「可能太宽」）
do {
    let f7 = FakeWindows(sampleWindows(solo), solo)
    f7.minWidth[21] = 1000   // 微信假装最小 1000 宽
    let st7 = StageManager(actions: f7, stash: StashManager(actions: f7, store: Store(dir: tmp.appendingPathComponent("stage7"))))
    st7.verifyDelay = 0
    st7.enter(focused: 13)
    var relaid = false
    st7.onRelayout = { _ in relaid = true }
    st7.setSpec(StageSpec(.split), fill: [21].compactMap { id in f7.wins.first { $0.id == id } })
    let slots7 = st7.stages["LAPTOP"]!.slots
    let f21 = f7.wins.first { $0.id == 21 }!.frame, f13 = f7.wins.first { $0.id == 13 }!.frame
    check(slots7 == [13, 21] && relaid, "微信留在副位，界面收到重排通知 \(slots7)")
    check(f21.width == 1000 && f13.maxX + 10 <= f21.minX + 1, "按最小宽度重新分配，不重叠 \(f13) \(f21)")
    check(!st7.fits(21, width: 700) && st7.fits(31, width: 700), "记住了微信的最小宽度")
    st7.exit()
}

// App 先接受窄尺寸、过一会儿自己弹回更宽（企业微信）：对账时补学最小宽度
do {
    let f9 = FakeWindows(sampleWindows(solo), solo)
    let st9 = StageManager(actions: f9, stash: StashManager(actions: f9, store: Store(dir: tmp.appendingPathComponent("stage9"))))
    st9.verifyDelay = 0; st9.promoteDelay = 0
    st9.enter(focused: 13)
    st9.setSpec(StageSpec(.split), fill: [21].compactMap { id in f9.wins.first { $0.id == id } })
    let i21 = f9.wins.firstIndex { $0.id == 21 }!
    f9.wins[i21].frame.size.width = 1000      // 自己弹宽了
    st9.settleDelay = 0
    st9.settle(released: true)
    check(!st9.fits(21, width: 741) && f9.wins.first { $0.id == 13 }!.frame.maxX + 10 <= f9.wins[i21].frame.minX + 1, "事后补学最小宽度并让位")
    st9.exit()
}

// 磁吸、拉边改比例、临时铺满、最小化请下台、关掉后补回上一个、撤销、窄窗口不变成浮窗
do {
    let f = FakeWindows(sampleWindows(solo), solo)
    let sm = StashManager(actions: f, store: Store(dir: tmp.appendingPathComponent("stage10")))
    let st = StageManager(actions: f, stash: sm); st.verifyDelay = 0; st.promoteDelay = 0; st.settleDelay = 0
    func w(_ id: UInt32) -> WindowInfo { f.wins.first { $0.id == id }! }
    func idx(_ id: UInt32) -> Int { f.wins.firstIndex { $0.id == id }! }
    st.enter(focused: 13)
    st.setSpec(StageSpec(.split), fill: [w(21)])
    let half = st.slotFrames("LAPTOP")
    // 挪歪了一点（没进别的格子）→ 吸回去
    f.wins[idx(13)].frame = half[0].offsetBy(dx: 60, dy: 200)
    check(st.settle(released: true) && w(13).frame == half[0], "挪歪的窗口松手后吸回格子 \(w(13).frame)")
    // 拉中间那条边：左边窗口右边缘往右拉 150 → 比例变大，右边窗口让位
    f.wins[idx(13)].frame.size.width += 150
    check(st.settle(released: true) && (st.stages["LAPTOP"]!.spec.ratio > 0.55), "拉中间的边改比例 \(st.stages["LAPTOP"]!.spec.ratio)")
    let nf = st.slotFrames("LAPTOP")
    check(w(13).frame == nf[0] && w(21).frame == nf[1] && nf[0].maxX + 10 == nf[1].minX, "右边窗口跟着让位")
    // App 自己变宽（不是你拖的）：不能当成拉边改比例
    let r0 = st.stages["LAPTOP"]!.spec.ratio
    let ii = f.wins.firstIndex { $0.id == 21 }!
    let t21 = st.slotFrames("LAPTOP")[1]
    f.wins[ii].frame = CGRect(x: t21.minX - 200, y: t21.minY, width: t21.width + 200, height: t21.height)
    let t0 = Date()
    _ = st.settle(now: t0); _ = st.settle(now: t0.addingTimeInterval(1.5))
    check(abs(st.stages["LAPTOP"]!.spec.ratio - r0) < 0.001, "App 自己往左变宽：不改比例（只有你拖的才改）")
    st.heal()
    // 撤销：比例回去
    check(st.undo() && abs(st.stages["LAPTOP"]!.spec.ratio - 0.5) < 0.01 && w(21).frame == half[1], "撤销：回到拉边之前")
    // 双击标题栏铺满：不拉回来；缩回去以后再归位
    f.wins[idx(21)].frame = laptop.visible
    check(!st.settle(released: true) && st.zoomed.contains(21), "临时铺满：尊重它，不拉回")
    f.wins[idx(21)].frame = CGRect(x: 900, y: 200, width: 500, height: 400)
    check(st.settle(released: true) && w(21).frame == half[1], "缩回来以后吸回格子")
    // ⌘Tab 换掉右边的窗口，再关掉新来的：刚才那个回来
    st.toggleLock(display: "LAPTOP", slot: 0)
    _ = st.onFocus(31)
    check(st.stages["LAPTOP"]!.slots == [13, 31] && sm.isStashed(21), "⌘Tab 换掉右边")
    f.wins.removeAll { $0.id == 31 }
    st.reconcile(mru: [])
    check(st.stages["LAPTOP"]!.slots == [13, 21] && !sm.isStashed(21) && w(21).frame == half[1], "关掉新来的：刚才那个回到格子里 \(st.stages["LAPTOP"]!.slots)")
    // 最小化 = 请下台
    f.wins[idx(21)].isMinimized = true
    st.reconcile(mru: [])
    check(st.stages["LAPTOP"]!.slots[1] == nil, "最小化：格子让出来")
    f.wins[idx(21)].isMinimized = false
    // 被摆成窄条的窗口不会变成「小浮窗」
    st.present(w(21), on: "LAPTOP", slot: 1)
    st.setSpec(StageSpec(.triple), fill: [w(12)])
    let sideID = st.stages["LAPTOP"]!.slots[2]!
    f.wins[idx(sideID)].frame.size.width = 340    // 别的窗口有最小宽度，侧栏被挤到 340
    check(st.stageable(w(sideID)), "三栏的窄侧栏里待过的窗口仍然算正常窗口（不会变成甩不掉的浮窗）")
    // 归位
    f.wins[idx(13)].frame = CGRect(x: 5, y: 300, width: 500, height: 400)
    st.heal()
    check(w(13).frame == st.slotFrames("LAPTOP")[0], "一键归位")
    st.exit()
}
check(StageManager.ratio(afterResizing: 1, of: StageSpec(.split), from: CGRect(x: 761, y: 43, width: 741, height: 900),
                         to: CGRect(x: 661, y: 43, width: 841, height: 900), in: laptop.visible, gap: 10).map { $0 < 0.45 } == true,
      "右边窗口往左拉左边缘：主位变窄")
check(StageManager.ratio(afterResizing: 1, of: StageSpec(.split), from: CGRect(x: 761, y: 43, width: 741, height: 900),
                         to: CGRect(x: 761, y: 43, width: 600, height: 900), in: laptop.visible, gap: 10) == nil,
      "拉的是外侧边：不改比例")

// 按格子摆：空着的格子保持位置，别的窗口不往前挤
do {
    let f = FakeWindows(sampleWindows(solo), solo)
    let st = StageManager(actions: f, stash: StashManager(actions: f, store: Store(dir: tmp.appendingPathComponent("stage12")))); st.verifyDelay = 0
    st.applySlots([("LAPTOP", StageSpec(.split), [nil, 21])])
    check(st.stages["LAPTOP"]?.slots == [nil, 21] && f.wins.first { $0.id == 21 }!.frame == st.slotFrames("LAPTOP")[1], "场景里第一格的窗口关了：第二格的窗口还在右边，不挪到左边")
    st.exit()
}

// 场景：跨屏场景拆成独立场景 + 组合；组合按上次的屏摆，屏不在就放到别的屏
do {
    var c = WorkContext(name: "回消息", emoji: "💬", color: 0, members: [])
    let m = { (b: String) in WorkContext.Member(bundleID: b, title: b) }
    c.plan = [ScenePlacement(displayUUID: "DELL", displayIndex: 1, spec: StageSpec(.triple), members: [m("dd"), m("tg"), m("ol")], name: "群聊"),
              ScenePlacement(displayUUID: "LAPTOP", displayIndex: 0, spec: StageSpec(.split), members: [m("wx"), m("wework")], name: "微信")]
    var single = WorkContext(name: "写代码", emoji: "💻", color: 1, members: [m("code")])
    single.plan = [ScenePlacement(displayUUID: "DELL", displayIndex: 1, spec: StageSpec(.focus), members: [m("code")])]
    let r = SceneBook.split([c, single])
    check(r.contexts.count == 3 && r.contexts.allSatisfy { $0.plan?.count == 1 } && r.combos.count == 1,
          "跨两块屏的场景拆成两个独立场景 + 一个组合 \(r.contexts.map(\.name))")
    check(r.contexts[0].id == c.id && r.contexts[0].name == "回消息 · 微信" && r.contexts[1].name == "回消息 · 群聊", "拆开的场景用 AI 给的分屏名字")
    let combo = r.combos[0]
    let both2 = SceneBook.assign(combo, to: both)
    check(both2.count == 2 && both2.first { $0.sceneID == r.contexts[0].id }?.display == "LAPTOP", "组合：每个场景回到上次那块屏")
    let only = SceneBook.assign(combo, to: solo)
    check(only.count == 1 && only[0].display == "LAPTOP", "拔了外接屏：组合只摆能摆的，不出错")
}

// 拔插外接屏：舞台不退出；拔掉的屏的场景记着，插回来自动恢复；滑到别的系统桌面时暂停
do {
    let f = FakeWindows(sampleWindows(both), both)
    let sm = StashManager(actions: f, store: Store(dir: tmp.appendingPathComponent("stage11")))
    let st = StageManager(actions: f, stash: sm); st.verifyDelay = 0; st.promoteDelay = 0; st.settleDelay = 0
    f.spaces = ["LAPTOP": 1, "DELL": 7]
    func w(_ id: UInt32) -> WindowInfo { f.wins.first { $0.id == id }! }
    st.enter(focused: 31)
    st.setSpec(StageSpec(.split), display: "DELL", fill: [w(12)])
    let dell = st.stages["DELL"]!.slots
    // 拔掉：系统把外接屏上的窗口挪到笔记本上
    f.prof = solo
    for i in f.wins.indices where !laptop.frame.intersects(f.wins[i].frame) {
        f.wins[i].frame = CGRect(x: 100, y: 100, width: 900, height: 700); f.wins[i].displayUUID = "LAPTOP"
    }
    st.displaysChanged()
    check(st.isActive && st.stages["DELL"] == nil && st.stages["LAPTOP"]?.slots == [31], "拔掉外接屏：舞台还在，笔记本不受影响 \(st.stages)")
    check(dell.compactMap { $0 }.allSatisfy { sm.isStashed($0) }, "外接屏上的窗口被挪过来后退到后台")
    // 插回来
    f.prof = both
    st.displaysChanged()
    check(st.stages["DELL"]?.slots == dell && dell.compactMap { $0 }.allSatisfy { external.visible.contains(w($0).frame) },
          "插回外接屏：它原来的场景自动摆回去 \(String(describing: st.stages["DELL"]?.slots))")
    // 滑到笔记本的另一个系统桌面：那里的窗口不被藏、切过去也不上台
    f.spaces["LAPTOP"] = 2
    let i21 = f.wins.firstIndex { $0.id == 21 }!
    sm.release(21)
    f.wins[i21].frame = CGRect(x: 200, y: 150, width: 800, height: 600); f.wins[i21].displayUUID = "LAPTOP"
    st.reconcile(mru: [])
    check(!sm.isStashed(21) && st.focusChanged(21) == .ignored, "在别的系统桌面上：Weft 暂停，不藏窗口、不抢着上台")
    f.spaces["LAPTOP"] = 1
    check(st.focusChanged(21) == .promoted, "回到舞台的桌面：恢复正常")
    st.exit()
}

// AI 场景解析：去掉不存在的窗口、超出版式的截断、空场景丢掉
do {
    let raw: [[String: Any]] = [
        ["name": "Weft 开发", "emoji": "🧵", "displays": [["display": 0, "layout": "split", "window_ids": [31, 11, 999, 12]]]],
        ["name": "回消息", "emoji": "💬", "displays": [["display": 1, "layout": "quad", "window_ids": [21, 41]]]],
        ["name": "空的", "emoji": "?", "displays": [["display": 0, "layout": "focus", "window_ids": [888]]]],
    ]
    let ps = Organizer.parse(raw, valid: [11, 12, 21, 31, 41], displayCount: 2)
    check(ps.count == 2 && ps[0].scenes[0].windowIDs == [31, 11] && ps[1].scenes[0].spec.layout == .split,
          "AI 场景：截断到版式格子数、四宫格只给两个 → 左右、空场景丢掉 \(ps.map(\.name))")
}

// 记忆：常见摆法、这个时间的习惯、笔记合并、标题归一化
do {
    let ms = MemoryStore(store: Store(dir: tmp.appendingPathComponent("memory")))
    let cal = Calendar.current
    func at(_ day: Int, _ hour: Int) -> Date { cal.date(bySettingHour: hour, minute: 10, second: 0, of: Date().addingTimeInterval(Double(-day) * 86400))! }
    let chat = [WorkContext.Member(bundleID: "com.tencent.xinWeChat", title: "微信 (3)", lastWindowID: nil),
                WorkContext.Member(bundleID: "com.tencent.WeWorkMac", title: "企业微信", lastWindowID: nil)]
    let code = [WorkContext.Member(bundleID: "com.microsoft.VSCode", title: "weft", lastWindowID: nil),
                WorkContext.Member(bundleID: "com.mitchellh.ghostty", title: "~", lastWindowID: nil)]
    for d in 1...3 {
        ms.log(ComboEntry(parts: [.init(displayIndex: 0, layout: .split, members: chat)], at: at(d, 9), minutes: 5))
        ms.log(ComboEntry(parts: [.init(displayIndex: 0, layout: .split, members: code)], at: at(d, 15), minutes: 40))
    }
    // 未读数变了也算同一种摆法
    var chat2 = chat; chat2[0].title = "微信 (12)"
    ms.log(ComboEntry(parts: [.init(displayIndex: 0, layout: .split, members: chat2)], at: at(4, 9), minutes: 5))
    let ps = ms.patterns()
    check(ps.count == 2 && ps.first?.count == 4, "常见摆法：两种，回消息 4 次（未读数不同也算同一种） \(ps.map(\.count))")
    check(ms.routine(at: at(0, 9))?.sample.parts[0].members[0].bundleID == "com.tencent.xinWeChat", "早上 9 点：通常在回消息")
    check(ms.routine(at: at(0, 15))?.sample.parts[0].members[0].bundleID == "com.microsoft.VSCode", "下午 3 点：通常在写代码")
    check(ms.routine(at: at(0, 21)) == nil, "晚上 9 点：没有固定习惯")
    ms.dismiss("routine:" + ps.first { $0.typicalHour == 9 }!.signature)
    check(ms.routine(at: at(0, 9)) == nil, "关掉的提示一周内不再出现")
    ms.add("微信永远放笔记本右边")
    ms.replaceAINotes(["早上先回消息", "微信永远放笔记本右边", "下午写 Weft"])
    check(ms.notes.count == 3 && ms.notes.filter { $0.source == .user }.count == 1, "AI 复盘不覆盖、不重复你写的笔记 \(ms.notes.map(\.text))")
    ms.replaceAINotes(["晚上看文档"])
    check(ms.notes.map(\.text) == ["微信永远放笔记本右边", "晚上看文档"], "再次复盘：替换旧的 AI 笔记")
    let reloaded = MemoryStore(store: Store(dir: tmp.appendingPathComponent("memory")))
    check(reloaded.notes.count == 2 && reloaded.combos.count == 7, "记忆存盘后能读回来")
    let st = MemoryStats.build(habits: HabitDB(), combos: ps, scenes: [:], redact: ["com.tencent.xinWeChat"])
    let arr = (st["frequent_arrangements"] as? [[String: Any]]) ?? []
    let wins = arr.flatMap { (($0["screens"] as? [[String: Any]]) ?? []).flatMap { ($0["windows"] as? [String]) ?? [] } }
    check(!wins.contains { $0.contains("微信 (") }, "发给 AI 复盘的统计里没有聊天窗口标题 \(wins)")
}

// 舞台开着时锁屏：什么都不能丢
do {
    let f8 = FakeWindows(sampleWindows(solo), solo)
    let sm8 = StashManager(actions: f8, store: Store(dir: tmp.appendingPathComponent("stage8")))
    let st8 = StageManager(actions: f8, stash: sm8); st8.verifyDelay = 0; st8.promoteDelay = 0
    st8.enter(focused: 13)
    let hiddenCount = sm8.entries.count
    f8.locked = true
    st8.reconcile(mru: [])
    sm8.prune(live: f8.windows())
    check(st8.stages["LAPTOP"]?.slots == [13] && sm8.entries.count == hiddenCount, "锁屏时对账：台上和后台记录都不动")
    check(!st8.exit() && st8.isActive, "锁屏时不退出舞台（放不回去）")
    sm8.restoreAll()
    check(sm8.entries.count == hiddenCount, "锁屏时 Weft 被关：后台记录留着，下次启动再放回")
    f8.locked = false
    check(st8.exit() && sm8.entries.isEmpty && !f8.wins.contains { !solo.displays[0].frame.intersects($0.frame) }, "解锁后退出：全部放回")
}

// MARK: - 同 App 多窗口

let wx2 = [win(21, "微信", "com.tencent.xinWeChat", "微信", CGRect(x: 100, y: 100, width: 900, height: 700), solo),
           win(22, "微信", "com.tencent.xinWeChat", "微信", CGRect(x: 1100, y: 60, width: 380, height: 520), solo),
           win(31, "iTerm2", "com.googlecode.iterm2", "zsh", CGRect(x: 0, y: 33, width: 756, height: 949), solo)]
let labels = WindowLabeler.labels(wx2, profile: solo)
check(labels[21]?.hasPrefix("主窗口") == true && labels[22]?.hasPrefix("小窗") == true && labels[22]?.contains("右上") == true,
      "两个微信窗口能区分：\(labels)")
check(labels[31] == nil, "只有一个窗口的 App 不加说明")

// MARK: - 整理

do {
    let p = solo
    let now = Date()
    let ws = [win(1, "Google Chrome", "com.google.Chrome", "新标签页", CGRect(x: 0, y: 33, width: 1200, height: 800), p),
              win(2, "Google Chrome", "com.google.Chrome", "GitHub", CGRect(x: 0, y: 33, width: 1200, height: 800), p, z: 1),
              win(3, "Google Chrome", "com.google.Chrome", "GitHub", CGRect(x: 0, y: 33, width: 1200, height: 800), p, z: 2),
              win(4, "访达", "com.apple.finder", "下载", CGRect(x: 0, y: 33, width: 900, height: 600), p, z: 3),
              win(5, "Visual Studio Code", "com.microsoft.VSCode", "欢迎 — weft", CGRect(x: 0, y: 33, width: 1200, height: 800), p, z: 4),
              win(6, "微信", "com.tencent.xinWeChat", "微信", CGRect(x: 0, y: 33, width: 900, height: 700), p, z: 5),
              win(7, "微信", "com.tencent.xinWeChat", "微信", CGRect(x: 0, y: 33, width: 400, height: 500), p, z: 6)]
    let last: [UInt32: Date] = [3: now.addingTimeInterval(-60), 2: now.addingTimeInterval(-3600), 4: now.addingTimeInterval(-5 * 86400)]
    let apps = [RunningApp(pid: 900, bundleID: "com.apple.Preview", name: "预览", isActive: false),
                RunningApp(pid: 901, bundleID: "com.tencent.qq", name: "QQ", isActive: false),
                RunningApp(pid: 902, bundleID: "com.apple.finder", name: "访达", isActive: false),
                RunningApp(pid: 1, bundleID: "com.google.Chrome", name: "Chrome", isActive: true)]
    var ws2 = ws
    for i in ws2.indices { ws2[i].pid = ws2[i].bundleID == "com.google.Chrome" ? 1 : ws2[i].bundleID == "com.apple.finder" ? 902 : 50 + Int32(i) }
    let items = TidyRules.scan(windows: ws2, apps: apps, focusedID: nil, lastFocused: { last[$0.id] }, now: now)
    let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    check(byID["w1"]?.kind == .empty && byID["w1"]?.checked == true, "新标签页 → 空窗口，默认勾选")
    check(byID["w5"]?.kind == .empty, "VS Code 欢迎页 → 空窗口")
    check(byID["w2"]?.kind == .duplicate && byID["w3"] == nil, "两个 GitHub：关掉旧的，留最近用的 \(items.map(\.id))")
    check(byID["w7"]?.kind == .duplicate && byID["w7"]?.checked == false, "两个同名微信窗口：只建议、不默认勾选")
    check(byID["w4"]?.kind == .stale && byID["w4"]?.action == .stash, "5 天没碰的访达窗口 → 收进后台")
    check(byID["a900"]?.action == .quit && byID["a900"]?.checked == true, "没窗口的预览 → 建议退出")
    check(byID["a901"]?.checked == false, "没窗口的 QQ：建议但不勾选（会收不到消息）")
    check(byID["a902"] == nil && byID["a1"] == nil, "访达、正在用的 App 不建议退出")
    check(!TidyRules.isEmptyTitle("新标签页设计讨论", bundleID: "com.google.Chrome") && TidyRules.isEmptyTitle("", bundleID: "com.google.Chrome")
          && !TidyRules.isEmptyTitle("", bundleID: "com.apple.finder"), "空标题判断不误伤")
    check(!TidyRules.isEmptyTitle("Untitled (social_ios) — Edited", bundleID: "com.navicat.NavicatPremium")
          && !TidyRules.isEmptyTitle("未命名 2 — 已编辑", bundleID: "com.apple.TextEdit")
          && TidyRules.isEmptyTitle("Untitled 3", bundleID: "com.apple.TextEdit"), "有改动的未命名文档不算空窗口")
    let terms = [win(81, "Ghostty", "com.mitchellh.ghostty", "~", CGRect(x: 0, y: 33, width: 900, height: 600), p),
                 win(82, "Ghostty", "com.mitchellh.ghostty", "~", CGRect(x: 0, y: 33, width: 900, height: 600), p, z: 1),
                 win(83, "Navicat Premium", "com.navicat.NavicatPremium", "Untitled", CGRect(x: 0, y: 33, width: 900, height: 600), p, z: 2)]
    check(TidyRules.scan(windows: terms, apps: [], focusedID: nil, lastFocused: { _ in nil }).isEmpty, "两个同名终端是不同会话、编辑器里的未命名可能在写：都不动")
    let ai = TidyAdvisor.parse([["window_id": 5, "action": "close", "reason": "欢迎页"], ["window_id": 2, "action": "close", "reason": "查完了"],
                                ["window_id": 3, "action": "keep", "reason": ""], ["window_id": 99, "action": "close", "reason": "x"],
                                ["window_id": 6, "action": "stash", "reason": "x"]],
                               windows: ws2, protected: [6])
    check(ai.count == 2 && ai.first { $0.windowID == 5 }?.action == .stash && ai.first { $0.windowID == 2 }?.checked == false,
          "AI 整理校验：编辑器 close 降级为收进后台、keep/不存在/正在用的去掉、AI 的关闭默认不勾 \(ai.map { ($0.windowID ?? 0, $0.action) })")
}

// MARK: - 数字槽位

do {
    let dir = tmp.appendingPathComponent("slots")
    let st = SlotStore(store: Store(dir: dir))
    let ws = sampleWindows(solo)
    st.assign(3, ws.first { $0.id == 21 }!)                 // 微信
    st.assign(1, ws.first { $0.id == 11 }!)                 // GitHub PR
    check(st.slot(of: 21) == 3, "钉住：微信在 3 号")
    st.assign(5, ws.first { $0.id == 21 }!)
    check(st.slot(of: 21) == 5 && st.bindings[3] == nil, "同一个窗口换号码：旧号码清空")
    check(st.resolve(5, windows: ws) == .window(ws.first { $0.id == 21 }!), "按 ID 命中")
    // 重启后窗口 ID 变了：同 App 同标题认回来
    var re = ws
    re[0].id = 111   // GitHub PR 新 ID
    re[3].id = 121   // 微信新 ID
    let st2 = SlotStore(store: Store(dir: dir))
    if case .window(let w) = st2.resolve(1, windows: re) { check(w.id == 111, "重启后按标题认回 GitHub PR") } else { check(false, "重启后认回 GitHub PR") }
    if case .window(let w) = st2.resolve(5, windows: re) { check(w.id == 121, "重启后认回微信") } else { check(false, "重启后认回微信") }
    check(st2.bindings[1]?.windowID == 111, "认领后记住新 ID")
    // 标题变了（换了个页面）：同 App 里最像的
    var re2 = re
    re2[0].title = "Pull requests · weft/weft - issue 12"
    re2[0].id = 211
    if case .window(let w) = st2.resolve(1, windows: re2) { check(w.id == 211 || w.bundleID == "com.google.Chrome", "标题变了也找回同 App 最像的窗口") }
    // 已被其他槽位占的窗口不抢
    st2.assign(2, re2.first { $0.id == 12 }!)
    if case .window(let w) = st2.resolve(1, windows: re2.filter { $0.id != 211 }) { check(w.id != 12, "不抢别的槽位钉住的窗口 \(w.id)") }
    // App 没开窗口：返回 App
    check(st2.resolve(5, windows: re.filter { $0.bundleID != "com.tencent.xinWeChat" }) == .app(bundleID: "com.tencent.xinWeChat", name: "微信"),
          "微信窗口都关了：⌥5 打开微信")
    check(st2.resolve(9, windows: re) == .empty, "空槽位")
    check(WeftSettings().slotModifier == .option && SlotModifier.controlOption.carbon == (KeyCombo.control | KeyCombo.option), "槽位修饰键默认 ⌥")
}

// MARK: - AI 排布解析 / 设置

let parsed = Arranger.parse([
    ["name": "专注写代码", "summary": "x", "scenes": [["display": 0, "layout": "triple", "window_ids": [31, 999, 11, 12, 13]],
                                                 ["display": 0, "layout": "focus", "window_ids": [21]],
                                                 ["display": 1, "layout": "main-stack", "ratio": 0.9, "window_ids": [41]]]],
    ["name": "坏方案", "scenes": [["display": 7, "layout": "split", "window_ids": [31]]]],
], valid: [11, 12, 13, 21, 31, 41], displayCount: 2)
check(parsed.count == 1 && parsed[0].scenes.count == 2, "AI 方案：丢掉重复屏幕 / 不存在的屏幕")
check(parsed[0].scenes[0].windowIDs == [31, 11, 12], "AI 方案：丢掉不存在的窗口、截断到版式容量")
check(parsed[0].scenes[1].spec.layout == .focus, "AI 方案：只有一个窗口的一主两辅退化成专注")

let legacyAI = try! JSONDecoder().decode(AIConfig.self, from: Data(#"{"source":"magpie","baseURL":"http://127.0.0.1:3425/v1","model":"x"}"#.utf8))
check(!legacyAI.isConfigured, "旧版自动导入的 Magpie 配置视为未配置，让用户自己选")
let st0 = try! JSONDecoder().decode(WeftSettings.self, from: Data("{}".utf8))
check(st0.hubTrigger == .doubleTap(.rightOption) && st0.quickSwitch == .combo(.optionTab) && !st0.setupDone, "设置默认值")
var st1 = WeftSettings(); st1.stageTrigger = .combo(KeyCombo(keyCode: 49, modifiers: KeyCombo.control | KeyCombo.option, display: "⌃⌥ Space"))
let st2 = try! JSONDecoder().decode(WeftSettings.self, from: JSONEncoder().encode(st1))
check(st2 == st1, "设置读写一致")
st1.stageTrigger = .doubleTap(.rightOption)
check(st1.conflicts().count == 1, "检测到两个功能用了同一个触发方式")

// MARK: 场景归屏：位置按笔记本 / 扩展屏从左到右，不认具体哪台显示器
do {
    check(both.roleMap == ["laptop": "LAPTOP", "ext1": "DELL"], "笔记本 + 一块外接屏的位置")
    check(solo.roleMap == ["laptop": "LAPTOP"], "只有笔记本")
    let home = DisplayInfo(id: 9, uuid: "HOME-LG", name: "LG", frame: CGRect(x: 1512, y: 0, width: 3840, height: 2160),
                           visible: CGRect(x: 1512, y: 25, width: 3840, height: 2135), isMain: false, isBuiltin: false)
    check(DisplayProfile(displays: [laptop, home]).role(of: "HOME-LG") == "ext1", "换了一台外接屏也还是扩展屏1")
    let left = DisplayInfo(id: 10, uuid: "LEFT", name: "左", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                           visible: CGRect(x: -1920, y: 25, width: 1920, height: 1055), isMain: false, isBuiltin: false)
    let three = DisplayProfile(displays: [laptop, external, left])
    check(three.role(of: "LEFT") == "ext1" && three.role(of: "DELL") == "ext2", "两块外接屏按从左到右排号")
    check(DisplayProfile(displays: [external]).roleMap == ["ext1": "DELL"], "合盖只接外接屏：没有笔记本")
    check(DisplayProfile.roleName("ext2") == "扩展屏2" && DisplayProfile.roleName("laptop") == "笔记本", "位置的名字")
    var c = WorkContext(name: "x", emoji: "🎬", color: 0, members: [])
    c.home = "ext1"
    let back = try? JSONDecoder().decode(WorkContext.self, from: JSONEncoder().encode(c))
    check(back?.home == "ext1", "场景所属的屏能存能读")
    let old = try? JSONDecoder().decode(WorkContext.self, from: Data(#"{"id":"a","name":"n","emoji":"e","color":0,"members":[],"layouts":{}}"#.utf8))
    check(old != nil && old?.home == nil, "老数据没有归屏字段也能读")
}


do {
    // 随手窗口 / 绑定
    let oldSettings = try? JSONDecoder().decode(WeftSettings.self, from: Data(#"{"setupDone":true}"#.utf8))
    check(oldSettings?.floatingApps == [], "老设置没有随手窗口字段也能读")
    var st = WeftSettings(); st.floatingApps = ["com.apple.finder"]
    check((try? JSONDecoder().decode(WeftSettings.self, from: JSONEncoder().encode(st)))?.floatingApps == ["com.apple.finder"], "随手窗口能存能读")
    let oldCombo = try? JSONDecoder().decode(SceneCombo.self, from: Data(#"{"id":"c","name":"n","emoji":"e","parts":[]}"#.utf8))
    check(oldCombo != nil && oldCombo?.isLinked == false, "老组合默认不联动")
    let lc = SceneCombo(name: "a+b", emoji: "🔗", parts: [], linked: true)
    check((try? JSONDecoder().decode(SceneCombo.self, from: JSONEncoder().encode(lc)))?.isLinked == true, "绑定能存能读")
    let f5 = FakeWindows(sampleWindows(both), both)
    let sm = StageManager(actions: f5, stash: StashManager(actions: f5, store: Store(dir: tmp.appendingPathComponent("float"))))
    let w0 = f5.wins.first { $0.frame.width >= 400 && $0.frame.height >= 300 }!
    check(sm.stageable(w0), "普通窗口能上台")
    sm.floatingApps = [w0.bundleID]
    check(!sm.stageable(w0), "随手 App 的窗口不上台（原样浮着）")
}

// 附属窗口：台上 App 自己弹出来的看图 / 预览窗口浮着，不进格子、不被藏、不问
do {
    let f = FakeWindows(sampleWindows(solo), solo)
    let sm = StashManager(actions: f, store: Store(dir: tmp.appendingPathComponent("companion")))
    let st = StageManager(actions: f, stash: sm); st.verifyDelay = 0; st.promoteDelay = 0; st.settleDelay = 0
    st.enter(focused: 13)
    st.reconcile()
    check(!st.companions.contains(21), "原来就开着的窗口不算附属窗口")
    // Chrome 在台上，它弹出一个新窗口（看图）
    f.wins.append(win(14, "Google Chrome", "com.google.Chrome", "图片预览", CGRect(x: 200, y: 200, width: 800, height: 600), solo, z: 0))
    check(st.focusChanged(14) == .ignored, "台上 App 弹出来的新窗口不上台、不问")
    check(st.companions.contains(14), "记成附属窗口")
    st.reconcile()
    check(!sm.isStashed(14) && !st.isOnStage(14), "附属窗口浮着，不被藏")
    // 别的 App 新开的窗口照旧
    f.wins.append(win(51, "备忘录", "com.apple.Notes", "新备忘录", CGRect(x: 300, y: 300, width: 800, height: 600), solo, z: 0))
    check(st.companionParent(of: f.wins.last!, live: f.wins) == nil, "别的 App 的新窗口不算附属")
    // 场景成员不算附属
    st.isSceneMember = { $0.id == 15 }
    f.wins.append(win(15, "Google Chrome", "com.google.Chrome", "Gmail", CGRect(x: 300, y: 300, width: 800, height: 600), solo, z: 0))
    check(st.companionParent(of: f.wins.last!, live: f.wins) == nil, "场景里的窗口不算附属")
    st.isSceneMember = nil
    // 主动放进舞台：不再是附属
    _ = st.present(f.wins.first { $0.id == 14 }!)
    check(!st.companions.contains(14) && st.isOnStage(14), "放进舞台后不再是附属窗口")
    // App 下台：附属窗口跟着退到后台
    f.wins.append(win(16, "Google Chrome", "com.google.Chrome", "另一张图", CGRect(x: 200, y: 200, width: 700, height: 500), solo, z: 0))
    st.reconcile()
    check(st.companions.contains(16), "新弹出的看图窗口浮着")
    st.applySlots([("LAPTOP", StageSpec(.focus), [21])])
    st.reconcile()
    check(!st.isOnStage(13) && !st.isOnStage(14), "Chrome 下台了")
    check(sm.isStashed(16) && !st.companions.contains(16), "App 下台后附属窗口跟着退到后台")
}

print("\n离线测试：\(passes) 通过，\(failures) 失败")

// MARK: - 在线测试：真实模型 + 假窗口（weft-selftest --live [model]）

if CommandLine.arguments.contains("--live") {
    let model = CommandLine.arguments.drop(while: { $0 != "--live" }).dropFirst().first ?? "auto/glm-5.3-flash"
    let cfg = AIConfig(provider: "magpie", baseURL: AIConfig.magpieBaseURL, model: model)
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let models = try await ModelDiscovery.listModels(baseURL: cfg.baseURL)
            print("Magpie 模型数：\(models.count)，支持工具调用：\(models.filter(\.supportsTools).count)")
            let cases: [(String, (FakeWindows) -> Bool)] = [
                ("把 GitHub 那个 Chrome 窗口放到主屏左半边，iTerm 放右半边", { f in
                    let gh = f.wins.first { $0.id == 11 }!.frame, it = f.wins.first { $0.id == 31 }!.frame
                    return gh == CGRect(x: 0, y: 33, width: 756, height: 949) && it == CGRect(x: 756, y: 33, width: 756, height: 949)
                }),
                ("把所有 Chrome 窗口在外接显示器上平铺成三列", { f in
                    let xs = f.wins.filter { $0.bundleID == "com.google.Chrome" }.map(\.frame.minX).sorted()
                    return xs.count == 3 && xs.allSatisfy { $0 >= 1512 } && Set(xs).count == 3
                }),
                ("我要专注写代码，把聊天软件都最小化", { f in
                    f.wins.first { $0.id == 21 }!.isMinimized && f.wins.first { $0.id == 41 }!.isMinimized
                    && !f.wins.first { $0.id == 31 }!.isMinimized
                }),
            ]
            var ok = 0
            for (instruction, verify) in cases {
                let f = FakeWindows(sampleWindows(both), both)
                let a = WindowAgent(config: cfg, actions: f)
                a.onEvent = { print("   \($0)") }
                let t0 = Date()
                let answer = try await a.run(instruction)
                let pass = verify(f)
                if pass { ok += 1 }
                print("\(pass ? "✓" : "✗") 「\(instruction)」 \(String(format: "%.1fs", Date().timeIntervalSince(t0)))\n   模型：\(answer)")
            }
            // AI 整理（分组）
            let org = Organizer(config: cfg)
            let t1 = Date()
            let advice = try await org.propose(Organizer.Input(windows: sampleWindows(both), profile: both, coUsage: [(11, 31, 6)],
                                                               minutes: [:], lastUsedDays: [:], desktops: [:], redact: []))
            let props = advice.proposals
            for p in props { print("   \(p.emoji) \(p.name)：\(p.windowIDs) — \(p.reason) \(p.scenes.map { "屏\($0.displayIndex) \($0.spec.layout.title)" })") }
            let devGroup = props.first { Set($0.windowIDs).isSuperset(of: [11, 31]) }
            let chat = props.first { $0.windowIDs.contains(21) }
            let orgOK = devGroup != nil && chat.map { !$0.windowIDs.contains(11) } ?? true
            if orgOK { ok += 1 }
            print("\(orgOK ? "✓" : "✗") AI 整理分组 \(String(format: "%.1fs", Date().timeIntervalSince(t1)))")
            // AI 排布
            let t2 = Date()
            let opts = try await Arranger(config: cfg).propose(ArrangeInput(
                windows: sampleWindows(both), profile: both, focused: 31, recent: [31, 11, 12, 21], coUsage: [(11, 31, 6)],
                contexts: [("Weft 开发", [11, 31])], redact: []))
            for o in opts {
                print("   ▸ \(o.name)：\(o.summary)")
                for sc in o.scenes { print("     屏 \(sc.displayIndex) \(sc.spec.layout.title) \(sc.spec.ratioLabel) → \(sc.windowIDs)") }
            }
            let arrOK = !opts.isEmpty && opts.contains { o in o.scenes.contains { Set($0.windowIDs).isSuperset(of: [31]) } }
            if arrOK { ok += 1 }
            print("\(arrOK ? "✓" : "✗") AI 排布 \(opts.count) 套方案 \(String(format: "%.1fs", Date().timeIntervalSince(t2)))")
            print("在线测试（\(model)）：\(ok)/\(cases.count + 2) 通过")
            if ok < cases.count + 2 { failures += 1 }
        } catch {
            print("在线测试失败：\(error)")
            failures += 1
        }
        sem.signal()
    }
    sem.wait()
}

try? FileManager.default.removeItem(at: tmp)
exit(failures == 0 ? 0 : 1)
