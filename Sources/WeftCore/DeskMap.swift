import AppKit

// MARK: - 桌面地图
//
// macOS 的「调度中心」里每块屏幕可以有很多个桌面（桌面 1、桌面 2…）。
// 窗口散落在各个桌面上，Weft 平时只看得到当前桌面的。这里把所有桌面、每个桌面上的窗口都列出来，
// 让「整理桌面」能看到全貌：哪些桌面是空的、哪些窗口躲在别的桌面里。

public struct DeskWindow: Equatable, Identifiable {
    public var id: UInt32
    public var pid: Int32
    public var appName: String
    public var bundleID: String
    public var title: String
}

public struct DeskSpace: Equatable, Identifiable {
    public var id: Int
    /// 在这块屏上的第几个桌面（从 1 开始，和调度中心里的「桌面 n」一致）
    public var index: Int
    public var isCurrent: Bool
    /// 全屏 App 占的桌面（不能删，也不算空桌面）
    public var isFullscreen: Bool
    public var windows: [DeskWindow]
    public var isEmpty: Bool { windows.isEmpty && !isFullscreen }
}

public struct DeskDisplay: Equatable, Identifiable {
    public var id: String { uuid }
    public var uuid: String
    public var name: String
    public var spaces: [DeskSpace]
    public var emptyCount: Int { spaces.filter(\.isEmpty).count }
}

public enum DeskMap {
    /// 读出每块屏的所有桌面和上面的窗口（只读，几毫秒）
    public static func read(profile: DisplayProfile) -> [DeskDisplay] {
        let cid = CGSMainConnectionID()
        guard let arr = CGSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        // 所有普通 App 的普通窗口
        let apps = Dictionary(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        let list = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var bySpace: [Int: [DeskWindow]] = [:]
        for item in list {
            guard (item[kCGWindowLayer as String] as? Int) == 0,
                  let id = item[kCGWindowNumber as String] as? UInt32,
                  let pid = item[kCGWindowOwnerPID as String] as? Int32, let app = apps[pid],
                  let bd = item[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd), b.width >= 120, b.height >= 80,
                  (item[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  app.bundleIdentifier != "local.weft.app" else { continue }
            let spaces = (CGSCopySpacesForWindows(cid, 7, [id] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []).map(\.intValue)
            // 属于好几个桌面的（「所有桌面」都显示的窗口）不算某个桌面的
            guard spaces.count == 1 else { continue }
            let w = DeskWindow(id: id, pid: pid, appName: app.localizedName ?? "", bundleID: app.bundleIdentifier ?? "",
                               title: item[kCGWindowName as String] as? String ?? "")
            bySpace[spaces[0], default: []].append(w)
        }
        return arr.compactMap { d in
            let uuid = d["Display Identifier"] as? String ?? ""
            let disp = profile.display(uuid: uuid) ?? (uuid == "Main" ? profile.main : nil)
            let current = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int
            let spaces = (d["Spaces"] as? [[String: Any]] ?? []).enumerated().compactMap { i, s -> DeskSpace? in
                guard let sid = s["ManagedSpaceID"] as? Int else { return nil }
                let full = (s["type"] as? Int ?? 0) != 0
                return DeskSpace(id: sid, index: i + 1, isCurrent: sid == current, isFullscreen: full, windows: bySpace[sid] ?? [])
            }
            guard !spaces.isEmpty else { return nil }
            return DeskDisplay(uuid: disp?.uuid ?? uuid, name: disp.map { $0.isBuiltin ? "笔记本屏" : $0.name } ?? "屏幕", spaces: spaces)
        }
    }

    /// 窗口 id → 它在哪块屏的第几个桌面（给 AI 看）
    public static func locations(_ map: [DeskDisplay]) -> [UInt32: (display: Int, desktop: Int)] {
        var out: [UInt32: (Int, Int)] = [:]
        for (di, d) in map.enumerated() { for s in d.spaces { for w in s.windows { out[w.id] = (di, s.index) } } }
        return out
    }
}
