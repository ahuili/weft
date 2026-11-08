import Foundation

// MARK: - 数字槽位
//
// 像给窗口编号：⌥⇧3 把当前窗口钉到 3 号，以后 ⌥3 一下直达，零查找。
// 再按一次 ⌥3（它已经在最前面）就回到刚才那个窗口，两个窗口之间来回只要一个键。
// 窗口 ID 重启后会变，所以同时记住 App 和标题：窗口关了、重开了，也能找回「同一个东西」；
// App 没开就打开它——⌥3 = 微信，永远有效。

public struct SlotBinding: Codable, Equatable {
    public var windowID: UInt32
    public var bundleID: String
    public var appName: String
    public var title: String
    public init(windowID: UInt32, bundleID: String, appName: String, title: String) {
        self.windowID = windowID; self.bundleID = bundleID; self.appName = appName; self.title = title
    }
}

public enum SlotTarget: Equatable {
    case window(WindowInfo)
    /// 窗口找不到但 App 还记得：打开 / 激活这个 App
    case app(bundleID: String, name: String)
    case empty
}

public final class SlotStore {
    public static let range = 1...9
    public private(set) var bindings: [Int: SlotBinding]
    private let store: Store

    public init(store: Store = .shared) {
        self.store = store
        let raw = store.load([String: SlotBinding].self, "slots.json") ?? [:]
        bindings = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    private func persist() {
        store.save(Dictionary(uniqueKeysWithValues: bindings.map { (String($0.key), $0.value) }), "slots.json")
    }

    /// 钉住。同一个窗口只占一个槽位（换到新号码）。返回被顶掉的旧绑定
    @discardableResult
    public func assign(_ n: Int, _ w: WindowInfo) -> SlotBinding? {
        guard Self.range.contains(n) else { return nil }
        for (k, b) in bindings where b.windowID == w.id { bindings[k] = nil }
        let old = bindings[n]
        bindings[n] = SlotBinding(windowID: w.id, bundleID: w.bundleID, appName: w.appName, title: w.title)
        persist()
        return old?.windowID == w.id ? nil : old
    }

    public func clear(_ n: Int) { bindings[n] = nil; persist() }

    /// 这个窗口钉在几号
    public func slot(of id: UInt32) -> Int? { bindings.first { $0.value.windowID == id }?.key }

    /// 找到槽位对应的窗口：同一个 ID → 同 App 同标题 → 同 App 标题最像的 → 只剩 App
    public func resolve(_ n: Int, windows: [WindowInfo]) -> SlotTarget {
        guard let b = bindings[n] else { return .empty }
        if let w = windows.first(where: { $0.id == b.windowID }) { return .window(w) }
        let same = windows.filter { $0.bundleID == b.bundleID }
        let taken = Set(bindings.filter { $0.key != n }.map(\.value.windowID))
        let free = same.filter { !taken.contains($0.id) }
        let pick = free.first { $0.title == b.title }
            ?? free.max { Self.similarity($0.title, b.title) < Self.similarity($1.title, b.title) }
        guard let pick else { return .app(bundleID: b.bundleID, name: b.appName) }
        // 认领新窗口，下次直接按 ID 命中
        bindings[n]?.windowID = pick.id
        bindings[n]?.title = pick.title
        persist()
        return .window(pick)
    }

    /// 标题相似度：共同的字符数（中文按字、英文按词），够用且稳定
    static func similarity(_ a: String, _ b: String) -> Int {
        func tokens(_ s: String) -> Set<String> {
            var out = Set<String>()
            for w in s.lowercased().split(whereSeparator: { " -—|·_/".contains($0) }) {
                if w.unicodeScalars.allSatisfy({ $0.isASCII }) { out.insert(String(w)) } else { w.forEach { out.insert(String($0)) } }
            }
            return out
        }
        return tokens(a).intersection(tokens(b)).count
    }
}
