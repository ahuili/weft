import Foundation

/// 「布局 = f(窗口, 显示器组合)」的调度中心：
/// - 显示器组合稳定时定期自动保存；
/// - 组合变化时，去抖后套用该组合的布局，没有就按上一个组合的布局做比例降级。
public final class LayoutEngine {
    public let actions: WindowActions
    public let store: Store
    public let undo = UndoStack()
    public private(set) var db: LayoutDB
    public var autoRestore = true
    public var log: (String) -> Void = { print($0) }
    /// 不参与布局的窗口（如已停靠到屏幕外的）
    public var exclude: () -> Set<UInt32> = { [] }

    private func liveWindows() -> [WindowInfo] {
        let ex = exclude()
        return actions.windows().filter { !ex.contains($0.id) }
    }

    private var currentFingerprint: String
    private var stableSince = Date()
    /// 显示器变化后的一段时间内暂停自动保存，避免把系统打乱后的布局存进去
    private var suspendAutosaveUntil = Date.distantPast

    public init(actions: WindowActions, store: Store = .shared) {
        self.actions = actions
        self.store = store
        self.db = store.load(LayoutDB.self, "layouts.json") ?? LayoutDB()
        self.currentFingerprint = actions.profile().fingerprint
    }

    private func persist() { store.save(db, "layouts.json") }

    // MARK: 手动

    @discardableResult
    public func saveManual() -> Layout {
        let p = actions.profile()
        let l = LayoutPlanner.capture(windows: liveWindows(), profile: p, manual: true)
        db.manual[p.fingerprint] = l
        db.auto[p.fingerprint] = l
        persist()
        log("已保存布局：\(l.windows.count) 个窗口 @ \(p.summary)")
        return l
    }

    /// 恢复当前显示器组合的布局，返回移动的窗口数
    @discardableResult
    public func restore(label: String = "恢复布局") -> Int {
        let p = actions.profile()
        guard let l = db.best(for: p.fingerprint) else {
            log("当前显示器组合没有保存过布局")
            return 0
        }
        return apply(layout: l, profile: p, label: label)
    }

    public func undoLast() -> String? { undo.undo(using: actions) }

    // MARK: 自动

    /// 定时调用（如每 20 秒）
    public func autosaveTick() {
        let p = actions.profile()
        guard p.fingerprint == currentFingerprint, Date() > suspendAutosaveUntil,
              Date().timeIntervalSince(stableSince) > 10 else { return }
        db.auto[p.fingerprint] = LayoutPlanner.capture(windows: liveWindows(), profile: p, manual: false)
        persist()
    }

    /// 显示器参数变化（已去抖）时调用
    public func displaysChanged() {
        let p = actions.profile()
        let old = currentFingerprint
        guard p.fingerprint != old else { return }
        currentFingerprint = p.fingerprint
        stableSince = Date()
        suspendAutosaveUntil = Date().addingTimeInterval(15)
        log("显示器变化：\(p.summary)")
        guard autoRestore else { return }

        if let l = db.best(for: p.fingerprint) {
            apply(layout: l, profile: p, label: "插拔屏自动恢复")
        } else if let prev = db.auto[old] ?? db.latestAuto {
            // 新组合没存过：用上一个组合的布局，按比例映射到现有屏幕
            apply(layout: prev, profile: p, label: "插拔屏比例降级")
        } else {
            let moves = LayoutPlanner.rescueOffscreen(windows: liveWindows(), profile: p)
            if !moves.isEmpty {
                undo.push("拉回屏幕外窗口", windows: actions.windows())
                Executor.apply(moves, using: actions)
            }
        }
    }

    @discardableResult
    private func apply(layout: Layout, profile: DisplayProfile, label: String) -> Int {
        let wins = liveWindows()
        let moves = LayoutPlanner.plan(layout: layout, windows: wins, profile: profile)
        guard !moves.isEmpty else { log("\(label)：布局已一致"); return 0 }
        undo.push(label, windows: wins)
        let n = Executor.apply(moves, using: actions)
        log("\(label)：调整 \(n) 个窗口")
        return n
    }
}
