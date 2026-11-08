import Foundation

/// 本地习惯学习：记录你在哪些窗口之间切换、什么时候用什么，用来预测「接下来要去哪」。
/// 全部在本机统计，不经过 AI。
public struct WindowStats: Codable {
    public var bundleID: String
    public var appName: String
    public var title: String
    public var focusCount: Int = 0
    public var focusSeconds: Double = 0
    public var lastFocused: Date = .distantPast
    public var hours: [Int] = Array(repeating: 0, count: 24)
}

public struct HabitDB: Codable {
    public var windows: [String: WindowStats] = [:]
    /// from key → to key → 次数
    public var transitions: [String: [String: Int]] = [:]
    public init() {}
}

public final class HabitTracker {
    public private(set) var db: HabitDB
    private let store: Store
    /// 本次运行中 windowID → 习惯 key（标题会变，比如 Chrome 切标签，所以首次见到时就固定 key）
    private var keyByID: [UInt32: String] = [:]
    private var current: (id: UInt32, key: String, since: Date)?
    /// 最近使用顺序（窗口 ID，最近的在前）
    public private(set) var mru: [UInt32] = []
    private var dirty = false

    public init(store: Store = .shared) {
        self.store = store
        self.db = store.load(HabitDB.self, "habits.json") ?? HabitDB()
    }

    public var currentWindowID: UInt32? { current?.id }

    public static func normalize(_ title: String) -> String {
        var t = title
        // 去掉未读数、常见浏览器后缀，减少同一窗口被拆成多个 key
        for suffix in [" - Google Chrome", " - Brave", " — Mozilla Firefox", " - Microsoft Edge"] {
            if t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        }
        t = t.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// 把 live 窗口映射到习惯 key：本次运行见过的用固定 key；否则按标题相似度找历史 key
    public func key(for w: WindowInfo) -> String {
        if let k = keyByID[w.id] { return k }
        let norm = Self.normalize(w.title)
        let exact = "\(w.bundleID)|\(norm)"
        var key = exact
        if db.windows[exact] == nil {
            let candidates = db.windows.filter { $0.value.bundleID == w.bundleID }
            if let best = candidates.max(by: {
                WindowMatcher.similarity($0.value.title, norm) < WindowMatcher.similarity($1.value.title, norm)
            }), WindowMatcher.similarity(best.value.title, norm) > 0.75 {
                key = best.key
            }
        }
        keyByID[w.id] = key
        return key
    }

    /// 每秒调用一次，传入当前聚焦窗口
    public func observe(focused: WindowInfo?, now: Date = Date()) {
        guard let w = focused else { return }
        if let c = current, c.id == w.id { return }
        let k = key(for: w)
        if let c = current {
            let dwell = now.timeIntervalSince(c.since)
            db.windows[c.key]?.focusSeconds += dwell
            // 停留超过 1.5 秒才算一次有效的切换，过滤掉 ⌥Tab 翻过的中间窗口
            if dwell > 1.5 { db.transitions[c.key, default: [:]][k, default: 0] += 1 }
        }
        var s = db.windows[k] ?? WindowStats(bundleID: w.bundleID, appName: w.appName, title: Self.normalize(w.title))
        s.focusCount += 1
        s.lastFocused = now
        s.hours[Calendar.current.component(.hour, from: now)] += 1
        db.windows[k] = s
        current = (w.id, k, now)
        mru.removeAll { $0 == w.id }
        mru.insert(w.id, at: 0)
        if mru.count > 200 { mru.removeLast() }
        dirty = true
    }

    public func persistIfNeeded() {
        guard dirty else { return }
        // 控制体积：只留最近 2000 个窗口
        if db.windows.count > 2000 {
            let keep = Set(db.windows.sorted { $0.value.lastFocused > $1.value.lastFocused }.prefix(1500).map(\.key))
            db.windows = db.windows.filter { keep.contains($0.key) }
            db.transitions = db.transitions.filter { keep.contains($0.key) }
        }
        store.save(db, "habits.json")
        dirty = false
    }

    /// 给每个 live 窗口打「接下来可能用」的分数
    public func predict(_ windows: [WindowInfo], now: Date = Date()) -> [UInt32: Double] {
        let hour = Calendar.current.component(.hour, from: now)
        let fromKey = current?.key
        let trans = fromKey.flatMap { db.transitions[$0] } ?? [:]
        let transTotal = Double(trans.values.reduce(0, +))
        var out: [UInt32: Double] = [:]
        for w in windows {
            let k = key(for: w)
            guard let s = db.windows[k] else { out[w.id] = 0; continue }
            let age = now.timeIntervalSince(s.lastFocused)
            let recency = exp(-age / 1800)                       // 半小时衰减
            let freq = log(1 + Double(s.focusCount)) / 4
            let totalHours = Double(max(s.hours.reduce(0, +), 1))
            let hourAff = Double(s.hours[hour] + s.hours[(hour + 23) % 24] + s.hours[(hour + 1) % 24]) / totalHours
            let tp = transTotal > 0 ? Double(trans[k] ?? 0) / transTotal : 0
            out[w.id] = 2.5 * recency + freq + 1.2 * hourAff + 3 * tp
        }
        if let c = current?.id { out[c] = (out[c] ?? 0) - 100 }   // 当前窗口不算「下一个」
        return out
    }

    /// 经常一起切换的窗口对（喂给 AI 做分组）
    public func coUsage(_ windows: [WindowInfo], top: Int = 40) -> [(UInt32, UInt32, Int)] {
        var idsByKey: [String: UInt32] = [:]
        for w in windows { idsByKey[key(for: w)] = w.id }
        var pairs: [Set<UInt32>: Int] = [:]
        for (a, tos) in db.transitions {
            guard let ia = idsByKey[a] else { continue }
            for (b, n) in tos {
                guard let ib = idsByKey[b], ia != ib else { continue }
                pairs[[ia, ib], default: 0] += n
            }
        }
        return pairs.sorted { $0.value > $1.value }.prefix(top).compactMap { p in
            let arr = Array(p.key)
            return arr.count == 2 ? (arr[0], arr[1], p.value) : nil
        }
    }

    public func lastFocused(_ w: WindowInfo) -> Date? { db.windows[key(for: w)]?.lastFocused }
    public func focusMinutes(_ w: WindowInfo) -> Double { (db.windows[key(for: w)]?.focusSeconds ?? 0) / 60 }
}
