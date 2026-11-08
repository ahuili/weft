import CoreGraphics
import Foundation

/// 布局里的一条记录：相对坐标 + 所在屏幕，而不是绝对像素。
public struct SavedWindow: Codable, Equatable {
    public var bundleID: String
    public var appName: String
    public var title: String
    public var displayUUID: String
    public var rel: CGRect          // 相对于该屏 visible 区域
    public var isMinimized: Bool

    public init(bundleID: String, appName: String, title: String, displayUUID: String,
                rel: CGRect, isMinimized: Bool) {
        self.bundleID = bundleID; self.appName = appName; self.title = title
        self.displayUUID = displayUUID; self.rel = rel; self.isMinimized = isMinimized
    }
}

public struct Layout: Codable {
    public var fingerprint: String
    public var profile: DisplayProfile
    public var windows: [SavedWindow]
    public var savedAt: Date
    public var manual: Bool

    public init(fingerprint: String, profile: DisplayProfile, windows: [SavedWindow], savedAt: Date, manual: Bool) {
        self.fingerprint = fingerprint; self.profile = profile; self.windows = windows
        self.savedAt = savedAt; self.manual = manual
    }
}

/// 一次布局变更的计划
public struct Move: Equatable {
    public var windowID: UInt32
    public var frame: CGRect
    public var minimize: Bool?
    public var reason: String

    public init(windowID: UInt32, frame: CGRect, minimize: Bool? = nil, reason: String) {
        self.windowID = windowID; self.frame = frame; self.minimize = minimize; self.reason = reason
    }
}

public enum LayoutPlanner {

    /// 把当前窗口拍成布局
    public static func capture(windows: [WindowInfo], profile: DisplayProfile, manual: Bool) -> Layout {
        let saved: [SavedWindow] = windows.compactMap { w in
            guard w.axAvailable,
                  let d = profile.display(uuid: w.displayUUID) ?? profile.display(containing: w.frame.center)
            else { return nil }
            return SavedWindow(bundleID: w.bundleID, appName: w.appName, title: w.title,
                               displayUUID: d.uuid, rel: w.frame.relative(to: d.visible),
                               isMinimized: w.isMinimized)
        }
        return Layout(fingerprint: profile.fingerprint, profile: profile, windows: saved,
                      savedAt: Date(), manual: manual)
    }

    /// 根据布局生成移动计划。
    /// - 布局里的屏幕在当前 profile 中找不到时，按相对坐标映射到主屏（「智能降级」）。
    public static func plan(layout: Layout, windows: [WindowInfo], profile: DisplayProfile) -> [Move] {
        let pairs = WindowMatcher.match(saved: layout.windows, live: windows.filter { $0.axAvailable })
        var moves: [Move] = []
        for (s, w) in pairs {
            let target = profile.display(uuid: s.displayUUID) ?? profile.main
            guard let target else { continue }
            let frame = s.rel.absolute(in: target.visible).clamped(to: target.visible)
            let fellBack = profile.display(uuid: s.displayUUID) == nil
            let needMove = !w.frame.isClose(to: frame) && !s.isMinimized
            let needMin = s.isMinimized != w.isMinimized
            guard needMove || needMin else { continue }
            moves.append(Move(windowID: w.id, frame: frame,
                              minimize: needMin ? s.isMinimized : nil,
                              reason: fellBack ? "原屏幕不在，按比例放到\(target.name)" : "恢复到\(target.name)"))
        }
        return moves
    }

    /// 没有任何布局可用时：只把跑到屏幕外的窗口拉回可见区域。
    public static func rescueOffscreen(windows: [WindowInfo], profile: DisplayProfile) -> [Move] {
        windows.compactMap { w in
            guard w.axAvailable, !w.isMinimized else { return nil }
            let visibleArea = profile.displays.map { $0.visible.intersection(w.frame) }
                .filter { !$0.isNull }
                .reduce(0.0) { $0 + $1.width * $1.height }
            let area = max(w.frame.width * w.frame.height, 1)
            guard visibleArea / area < 0.5, let d = profile.main else { return nil }
            return Move(windowID: w.id, frame: w.frame.clamped(to: d.visible), reason: "窗口在屏幕外，拉回主屏")
        }
    }
}

extension CGRect {
    func isClose(to o: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(minX - o.minX) <= tolerance && abs(minY - o.minY) <= tolerance &&
        abs(width - o.width) <= tolerance && abs(height - o.height) <= tolerance
    }
}

/// 窗口身份跟踪：CGWindowID 重启就变，所以用「App + 标题相似度」配对。
public enum WindowMatcher {

    public static func match(saved: [SavedWindow], live: [WindowInfo]) -> [(SavedWindow, WindowInfo)] {
        var result: [(SavedWindow, WindowInfo)] = []
        let byApp = Dictionary(grouping: live, by: { $0.bundleID })
        let savedByApp = Dictionary(grouping: saved, by: { $0.bundleID })
        for (app, savedList) in savedByApp {
            guard var pool = byApp[app], !pool.isEmpty else { continue }
            // 所有 (saved, live) 组合打分，贪心取最高
            var scored: [(Int, Int, Double)] = []
            for (i, s) in savedList.enumerated() {
                for (j, w) in pool.enumerated() {
                    scored.append((i, j, similarity(s.title, w.title)))
                }
            }
            scored.sort { $0.2 > $1.2 }
            var usedS = Set<Int>(), usedL = Set<Int>()
            for (i, j, _) in scored where !usedS.contains(i) && !usedL.contains(j) {
                usedS.insert(i); usedL.insert(j)
                result.append((savedList[i], pool[j]))
            }
            pool.removeAll()
        }
        return result
    }

    /// 0…1 的标题相似度：token Jaccard 与归一化编辑距离取较大者
    public static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let ta = Set(tokens(a)), tb = Set(tokens(b))
        let jac = ta.isEmpty || tb.isEmpty ? 0 : Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
        let ea = Array(a.prefix(80)), eb = Array(b.prefix(80))
        let ed = 1 - Double(levenshtein(ea, eb)) / Double(max(ea.count, eb.count))
        return max(jac, ed)
    }

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

/// 区域：AI 与键盘分屏共用的语义化位置
public enum Region: String, CaseIterable, Codable {
    case maximize, center
    case leftHalf = "left-half", rightHalf = "right-half", topHalf = "top-half", bottomHalf = "bottom-half"
    case leftThird = "left-third", centerThird = "center-third", rightThird = "right-third"
    case leftTwoThirds = "left-two-thirds", rightTwoThirds = "right-two-thirds"
    case topLeft = "top-left", topRight = "top-right", bottomLeft = "bottom-left", bottomRight = "bottom-right"

    public var rel: CGRect {
        switch self {
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .center: return CGRect(x: 0.15, y: 0.1, width: 0.7, height: 0.8)
        case .leftHalf: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .leftThird: return CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)
        case .centerThird: return CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .rightThird: return CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .leftTwoThirds: return CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1)
        case .rightTwoThirds: return CGRect(x: 1.0 / 3, y: 0, width: 2.0 / 3, height: 1)
        case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        }
    }

    /// 把 n 个窗口平铺成列 / 行 / 网格
    public static func tile(count n: Int, arrangement: String) -> [CGRect] {
        guard n > 0 else { return [] }
        switch arrangement {
        case "rows":
            return (0..<n).map { CGRect(x: 0, y: Double($0) / Double(n), width: 1, height: 1 / Double(n)) }
        case "grid":
            let cols = Int(Double(n).squareRoot().rounded(.up))
            let rows = Int((Double(n) / Double(cols)).rounded(.up))
            return (0..<n).map { i in
                CGRect(x: Double(i % cols) / Double(cols), y: Double(i / cols) / Double(rows),
                       width: 1 / Double(cols), height: 1 / Double(rows))
            }
        default: // columns
            return (0..<n).map { CGRect(x: Double($0) / Double(n), y: 0, width: 1 / Double(n), height: 1) }
        }
    }
}
