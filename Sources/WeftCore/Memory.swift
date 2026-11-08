import Foundation

// MARK: - 记忆
//
// Weft 记得你怎么工作：
// 1. 组合日志（本机，不经过 AI）：舞台上一组窗口稳定摆了几分钟，就记一笔「几点、哪几个窗口在一起、怎么摆」；用了哪个场景也记一笔。
// 2. 记忆笔记：AI 定期把这些统计「复盘」成几句人话（「早上 9~10 点先回钉钉和邮件」），你可以改、删、自己加（「微信永远放笔记本右边」）。
//    所有 AI 功能（场景、排布、清理）都会先读这些笔记。
// 3. 用起来：空的数字槽位推荐最常用的窗口；侧栏「此刻」提示这个时间你通常在做的场景；常这样摆就提示存成场景。

public struct MemoryNote: Codable, Identifiable, Equatable {
    public enum Source: String, Codable { case ai, user }
    public var id: String
    public var text: String
    public var source: Source
    public var updatedAt: Date
    public init(id: String = UUID().uuidString, text: String, source: Source, updatedAt: Date = Date()) {
        self.id = id; self.text = text; self.source = source; self.updatedAt = updatedAt
    }
}

/// 一组在舞台上一起待过的窗口
public struct ComboEntry: Codable, Equatable {
    /// 每块屏：版式 + 窗口（按格子顺序）
    public struct Part: Codable, Equatable {
        public var displayIndex: Int
        public var layout: StageLayout
        public var members: [WorkContext.Member]
        public init(displayIndex: Int, layout: StageLayout, members: [WorkContext.Member]) {
            self.displayIndex = displayIndex; self.layout = layout; self.members = members
        }
    }
    public init(parts: [Part], at: Date, minutes: Double, sceneID: String? = nil) {
        self.parts = parts; self.at = at; self.minutes = minutes; self.sceneID = sceneID
    }
    public var parts: [Part]
    public var at: Date
    /// 摆了多久（分钟）
    public var minutes: Double
    /// 来自哪个场景（用场景摆出来的）
    public var sceneID: String?

    /// 用来判断「是不是同一种摆法」：成员的 App + 标题，不管顺序
    public var signature: String {
        parts.flatMap { $0.members.map { "\($0.bundleID)|\(MemoryStore.normalize($0.title))" } }.sorted().joined(separator: "&")
    }
    public var memberCount: Int { parts.reduce(0) { $0 + $1.members.count } }
}

public struct MemoryDB: Codable {
    public var notes: [MemoryNote] = []
    public var combos: [ComboEntry] = []
    /// 被你关掉的提示（签名 → 关掉的时间），一周内不再提
    public var dismissed: [String: Date] = [:]
    public var lastDigest: Date?
    public var enabled = true
    public init() {}
}

public final class MemoryStore {
    public private(set) var db: MemoryDB
    private let store: Store
    public init(store: Store = .shared) {
        self.store = store
        db = store.load(MemoryDB.self, "memory.json") ?? MemoryDB()
    }

    public func save() { store.save(db, "memory.json") }

    public var enabled: Bool {
        get { db.enabled }
        set { db.enabled = newValue; save() }
    }

    // MARK: 笔记

    public var notes: [MemoryNote] { db.notes }

    public func add(_ text: String, source: MemoryNote.Source = .user) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        db.notes.append(MemoryNote(text: t, source: source))
        save()
    }

    public func update(_ id: String, text: String) {
        guard let i = db.notes.firstIndex(where: { $0.id == id }) else { return }
        db.notes[i].text = text
        db.notes[i].source = .user      // 改过的就算你的，AI 复盘不会覆盖
        db.notes[i].updatedAt = Date()
        save()
    }

    public func remove(_ id: String) { db.notes.removeAll { $0.id == id }; save() }

    /// AI 复盘结果：替换掉旧的 AI 笔记，你写的 / 改过的保留
    public func replaceAINotes(_ texts: [String], now: Date = Date()) {
        db.notes.removeAll { $0.source == .ai }
        let mine = Set(db.notes.map { Self.normalize($0.text) })
        for t in texts.prefix(10) where !mine.contains(Self.normalize(t)) {
            db.notes.append(MemoryNote(text: t, source: .ai, updatedAt: now))
        }
        db.lastDigest = now
        save()
    }

    /// 给 AI 看的记忆（一行一条）
    public var promptLines: [String] { db.enabled ? db.notes.map(\.text) : [] }

    public func clearAll() { db = MemoryDB(); save() }

    // MARK: 组合日志

    public func log(_ e: ComboEntry) {
        guard db.enabled, e.memberCount > 0 else { return }
        db.combos.append(e)
        // 只留最近 60 天、最多 600 条
        let cutoff = e.at.addingTimeInterval(-60 * 86400)
        db.combos.removeAll { $0.at < cutoff }
        if db.combos.count > 600 { db.combos.removeFirst(db.combos.count - 600) }
        save()
    }

    public var combos: [ComboEntry] { db.combos }

    public func dismiss(_ signature: String, now: Date = Date()) { db.dismissed[signature] = now; save() }
    public func isDismissed(_ signature: String, now: Date = Date()) -> Bool {
        guard let d = db.dismissed[signature] else { return false }
        return now.timeIntervalSince(d) < 7 * 86400
    }

    // MARK: 分析（本机）

    /// 常见摆法：同一种组合出现了几次（不同的天 / 时段）、平均几点
    public struct Pattern: Equatable {
        public var signature: String
        public var sample: ComboEntry
        public var count: Int
        public var days: Int
        public var hours: [Int]
        public var sceneID: String?
        public var typicalHour: Int {
            guard !hours.isEmpty else { return 0 }
            return hours.sorted()[hours.count / 2]
        }
    }

    public func patterns(minCount: Int = 3) -> [Pattern] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: db.combos.filter { $0.memberCount >= 2 || $0.sceneID != nil }) { $0.sceneID ?? $0.signature }
        return groups.compactMap { _, es in
            let days = Set(es.map { cal.startOfDay(for: $0.at) }).count
            guard es.count >= minCount, days >= 2, let last = es.max(by: { $0.at < $1.at }) else { return nil }
            return Pattern(signature: last.signature, sample: last, count: es.count, days: days,
                           hours: es.map { cal.component(.hour, from: $0.at) }, sceneID: last.sceneID)
        }.sorted { $0.count > $1.count }
    }

    /// 这个时间你通常在用哪种摆法（前后 1 小时内，至少在 2 天里出现过）
    public func routine(at now: Date = Date()) -> Pattern? {
        let h = Calendar.current.component(.hour, from: now)
        return patterns(minCount: 2).first { p in
            let near = p.hours.filter { abs($0 - h) <= 1 || abs($0 - h) == 23 }.count
            return near >= 2 && Double(near) / Double(p.hours.count) >= 0.5 && !isDismissed("routine:" + p.signature, now: now)
        }
    }

    /// 标题里的数字、未读数之类去掉，「微信 (3)」和「微信」算同一个
    public static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        t = t.replacingOccurrences(of: #"[\(\[（【]\d+[\)\]）】]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - 给 AI 复盘用的统计

public enum MemoryStats {
    /// 把本机统计压成一份小 JSON：每个时段最常用的窗口、常见摆法、常一起切换的窗口对
    public static func build(habits: HabitDB, combos: [MemoryStore.Pattern], scenes: [String: String], redact: Set<String> = []) -> [String: Any] {
        // 聊天软件只发 App 名
        func t(_ bundle: String, _ title: String) -> String { redact.contains(bundle) ? "" : String(title.prefix(60)) }
        let dayparts: [(String, ClosedRange<Int>)] = [("早上 6-11", 6...11), ("下午 12-17", 12...17), ("晚上 18-23", 18...23), ("深夜 0-5", 0...5)]
        var byPart: [String: [[String: Any]]] = [:]
        for (name, range) in dayparts {
            let top = habits.windows.values
                .map { s in (s, range.reduce(0) { $0 + s.hours[$1] }) }
                .filter { $0.1 >= 10 }
                .sorted { $0.1 > $1.1 }
                .prefix(8)
            if !top.isEmpty {
                byPart[name] = top.map { s, n in ["app": s.appName, "title": t(s.bundleID, s.title), "seconds": n] }
            }
        }
        let total = habits.windows.values.sorted { $0.focusSeconds > $1.focusSeconds }.prefix(15).map { s -> [String: Any] in
            ["app": s.appName, "title": t(s.bundleID, s.title), "minutes": Int(s.focusSeconds / 60)]
        }
        let patterns = combos.prefix(10).map { p -> [String: Any] in
            var o: [String: Any] = [
                "times": p.count, "days": p.days, "typical_hour": p.typicalHour,
                "screens": p.sample.parts.map { part in
                    ["display": part.displayIndex, "layout": part.layout.rawValue,
                     "windows": part.members.map { "\($0.bundleID.split(separator: ".").last ?? "") · \(t($0.bundleID, $0.title).prefix(40))" }] as [String: Any]
                },
            ]
            if let id = p.sceneID, let n = scenes[id] { o["scene"] = n }
            return o
        }
        return ["by_time_of_day": byPart, "most_used": total, "frequent_arrangements": patterns]
    }
}
