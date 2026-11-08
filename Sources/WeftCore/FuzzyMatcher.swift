import Foundation

/// 中文转拼音（全拼 + 首字母），结果做缓存。
public enum Pinyin {
    private static var cache: [String: (full: String, initials: String)] = [:]
    private static let lock = NSLock()

    public static func convert(_ s: String) -> (full: String, initials: String) {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[s] { return c }
        guard s.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else {
            let r = (s.lowercased(), "")
            cache[s] = r
            return r
        }
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
        let latin = (m as String).lowercased()
        // 首字母：只取原文中汉字对应的音节首字母
        var initials = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
                let one = NSMutableString(string: String(ch))
                CFStringTransform(one, nil, kCFStringTransformMandarinLatin, false)
                CFStringTransform(one, nil, kCFStringTransformStripDiacritics, false)
                if let f = (one as String).lowercased().first { initials.append(f) }
            } else if ch.isLetter || ch.isNumber {
                initials.append(contentsOf: ch.lowercased())
            }
            i = s.index(after: i)
        }
        let r = (latin.replacingOccurrences(of: " ", with: ""), initials)
        cache[s] = r
        return r
    }
}

/// 类 fzf 的模糊匹配：查询按空格切成多个词，每个词都必须命中；
/// 命中方式可以是原文子序列、拼音全拼子序列、拼音首字母子序列。
public enum FuzzyMatcher {

    /// 返回分数（越高越好），不匹配返回 nil。
    public static func score(query: String, candidates fields: [String]) -> Double? {
        let tokens = query.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        if tokens.isEmpty { return 0 }
        var haystacks: [String] = []
        for f in fields where !f.isEmpty {
            haystacks.append(f.lowercased())
            let py = Pinyin.convert(f)
            if !py.initials.isEmpty {
                haystacks.append(py.full)
                haystacks.append(py.initials)
            }
        }
        var total = 0.0
        for t in tokens {
            var best: Double? = nil
            for (idx, h) in haystacks.enumerated() {
                if let s = subsequenceScore(t, in: h) {
                    // 越靠前的字段（App 名 / 标题）权重越高
                    let weighted = s * (1.0 - Double(min(idx, 6)) * 0.03)
                    best = max(best ?? -1, weighted)
                }
            }
            guard let b = best else { return nil }
            total += b
        }
        return total
    }

    /// 子序列打分：连续命中、词首命中、开头命中加分；跨度越大扣分。
    static func subsequenceScore(_ needle: String, in hay: String) -> Double? {
        let n = Array(needle), h = Array(hay)
        guard !n.isEmpty, n.count <= h.count else { return n.isEmpty ? 0 : nil }
        // 优先：整段子串命中
        if let r = hay.range(of: needle) {
            let pos = hay.distance(from: hay.startIndex, to: r.lowerBound)
            let atWordStart = pos == 0 || !h[pos - 1].isLetter
            return 10.0 * Double(n.count) + (pos == 0 ? 8 : 0) + (atWordStart ? 4 : 0) - Double(pos) * 0.05
        }
        var score = 0.0
        var hi = 0
        var last = -2
        var first = -1
        for c in n {
            var found = false
            while hi < h.count {
                if h[hi] == c {
                    if first < 0 { first = hi }
                    let wordStart = hi == 0 || !h[hi - 1].isLetter
                    score += 1
                    if hi == last + 1 { score += 3 }
                    if wordStart { score += 2 }
                    last = hi
                    hi += 1
                    found = true
                    break
                }
                hi += 1
            }
            if !found { return nil }
        }
        let span = Double(last - first + 1)
        score -= (span - Double(n.count)) * 0.2
        return score
    }

    /// 对窗口列表排序过滤。空查询时按 z 序（最近使用）返回。
    public static func rank(_ windows: [WindowInfo], query: String) -> [WindowInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return windows.sorted { $0.zIndex < $1.zIndex } }
        return windows
            .compactMap { w -> (WindowInfo, Double)? in
                guard let s = score(query: q, candidates: [w.appName, w.title, w.bundleID]) else { return nil }
                return (w, s - Double(w.zIndex) * 0.01)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }
}
