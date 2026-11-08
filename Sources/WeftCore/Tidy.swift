import Foundation

// MARK: - 整理
//
// 一键体检：空窗口、重复窗口、好几天没碰的窗口、开着却没窗口的 App。
// 规则即时给出（不需要 AI）；配了 AI 还能做更深的判断（「这几个搜索页已经查完了」）。
// 所有建议都先列出来、能勾选，确认后才执行；聊天类 App 永远不默认退出（会收不到消息）。

public enum TidyAction: String, Codable, CaseIterable {
    case close      // 关闭窗口
    case stash      // 收进后台（不关，随时叫回）
    case minimize   // 最小化
    case quit       // 退出 App

    public var title: String {
        switch self {
        case .close: return "关闭"
        case .stash: return "收进后台"
        case .minimize: return "最小化"
        case .quit: return "退出 App"
        }
    }
}

public enum TidyKind: String, Codable {
    case empty, duplicate, stale, idleApp, ai

    public var title: String {
        switch self {
        case .empty: return "空窗口"
        case .duplicate: return "重复的窗口"
        case .stale: return "好几天没碰"
        case .idleApp: return "开着却没在用的 App"
        case .ai: return "AI 建议"
        }
    }
}

public struct TidyItem: Identifiable, Equatable {
    /// 窗口：w<id>；App：a<pid>
    public var id: String
    public var kind: TidyKind
    public var action: TidyAction
    public var windowID: UInt32?
    public var pid: Int32
    public var bundleID: String
    public var appName: String
    public var title: String
    public var reason: String
    /// 默认勾选（只给「几乎不可能误伤」的）
    public var checked: Bool

    public init(kind: TidyKind, action: TidyAction, windowID: UInt32?, pid: Int32, bundleID: String,
                appName: String, title: String, reason: String, checked: Bool) {
        self.id = windowID.map { "w\($0)" } ?? "a\(pid)"
        self.kind = kind; self.action = action; self.windowID = windowID; self.pid = pid
        self.bundleID = bundleID; self.appName = appName; self.title = title; self.reason = reason; self.checked = checked
    }
}

public struct RunningApp: Equatable {
    public var pid: Int32
    public var bundleID: String
    public var name: String
    public var isActive: Bool
    public init(pid: Int32, bundleID: String, name: String, isActive: Bool) {
        self.pid = pid; self.bundleID = bundleID; self.name = name; self.isActive = isActive
    }
}

public enum TidyRules {
    /// 退出会收不到消息 / 会断开的 App：可以建议，但绝不默认勾选
    public static let messaging: Set<String> = [
        "com.tencent.xinWeChat", "com.tencent.qq", "com.tencent.WeWorkMac", "com.alibaba.DingTalkMac",
        "com.electron.lark", "com.bytedance.lark.Feishu", "ru.keepcoder.Telegram", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "com.microsoft.teams2", "com.apple.mail", "com.microsoft.Outlook", "com.netease.macmail",
        "com.apple.MobileSMS", "com.tencent.meeting", "com.apple.FaceTime",
    ]
    /// 平时就没窗口、或退出会出问题的，不建议退出
    public static let neverQuit: Set<String> = [
        "com.apple.finder", "local.weft.app", "com.anthropic.claudefordesktop", "com.apple.dock",
        "io.github.clash-verge-rev.clash-verge-rev", "com.1password.1password", "com.bjango.istatmenus",
        "com.apple.systempreferences", "com.apple.Music", "com.netease.163music", "com.apple.ActivityMonitor",
    ]
    /// 终端 / 编辑器：同名窗口是不同的会话或文件，不算重复，也不建议关
    public static let sessions: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "org.tabby", "net.kovidgoyal.kitty",
        "io.alacritty", "dev.warp.Warp-Stable", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.trae.app",
        "com.exafunction.windsurf", "com.navicat.NavicatPremium", "com.tinyapp.TablePlus",
    ]
    /// 同名窗口基本就是重复的：可以默认勾选
    static let safeDuplicates: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "com.brave.Browser", "org.mozilla.firefox", "com.microsoft.edgemac",
        "com.apple.finder", "com.apple.Preview",
    ]
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "com.brave.Browser", "org.mozilla.firefox", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.openai.atlas",
    ]
    static let emptyTitles = [
        "新标签页", "new tab", "untitled", "未命名", "无标题", "start page", "起始页", "about:blank", "收藏夹",
        "favorites", "welcome", "欢迎使用", "空白页", "新窗口",
    ]

    public static func isEmptyTitle(_ title: String, bundleID: String) -> Bool {
        var t = title.trimmingCharacters(in: .whitespaces).lowercased()
        for suffix in [" - google chrome", " — google chrome", " - brave", " — brave", " - microsoft edge", " — mozilla firefox"] {
            if t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        }
        if t.isEmpty { return browsers.contains(bundleID) }
        // 有改动 / 有内容的绝不算空：「Untitled (social_ios) — Edited」「未命名 2 — 已编辑」
        if t.contains("edited") || t.contains("已编辑") || t.contains("已修改") || t.contains("•") || t.contains("●") { return false }
        // 只认「整个标题就是空白页名」或「空白页名 + 编号」，如「Untitled」「未命名 3」
        if emptyTitles.contains(where: { e in
            t == e || (t.hasPrefix(e + " ") && t.dropFirst(e.count + 1).allSatisfy(\.isNumber))
        }) { return true }
        // VS Code 之类：「欢迎 — xxx」「Welcome — xxx」
        if t.hasPrefix("welcome —") || t.hasPrefix("欢迎 —") || t.hasPrefix("欢迎使用 —") { return true }
        return false
    }

    /// staleDays：多久没碰算「好几天」
    public static func scan(windows: [WindowInfo], apps: [RunningApp], focusedID: UInt32?,
                            lastFocused: (WindowInfo) -> Date?, now: Date = Date(), staleDays: Double = 3) -> [TidyItem] {
        var out: [TidyItem] = []
        var used = Set<UInt32>()
        let wins = windows.filter { $0.id != focusedID }

        // 1) 空窗口
        // 终端 / 编辑器里只认「欢迎页」，未命名的可能正在写
        for w in wins where isEmptyTitle(w.title, bundleID: w.bundleID)
            && (!sessions.contains(w.bundleID) || w.title.lowercased().hasPrefix("welcome") || w.title.hasPrefix("欢迎")) {
            out.append(TidyItem(kind: .empty, action: .close, windowID: w.id, pid: w.pid, bundleID: w.bundleID,
                                appName: w.appName, title: w.title.isEmpty ? "（无标题）" : w.title,
                                reason: "空白页 / 未命名，没有内容", checked: true))
            used.insert(w.id)
        }

        // 2) 重复：同一个 App、同一个标题，留最近用过的那个
        let groups = Dictionary(grouping: windows.filter { !used.contains($0.id) && !$0.title.isEmpty && !sessions.contains($0.bundleID) }) { "\($0.bundleID)|\($0.title)" }
        for (_, ws) in groups where ws.count > 1 {
            let keep = ws.min { a, b in
                if a.id == focusedID { return true }
                if b.id == focusedID { return false }
                let la = lastFocused(a) ?? .distantPast, lb = lastFocused(b) ?? .distantPast
                return la != lb ? la > lb : a.zIndex < b.zIndex
            }!
            for w in ws where w.id != keep.id {
                // 聊天软件的多个同名窗口可能是不同会话，只建议不勾选
                let safe = safeDuplicates.contains(w.bundleID)
                out.append(TidyItem(kind: .duplicate, action: .close, windowID: w.id, pid: w.pid, bundleID: w.bundleID,
                                    appName: w.appName, title: w.title,
                                    reason: safe ? "和另一个窗口内容一样，保留最近用的那个" : "和另一个「\(w.appName)」窗口同名，可能是同一个界面（先看一眼再决定）",
                                    checked: safe))
                used.insert(w.id)
            }
        }

        // 3) 好几天没碰的窗口：收进后台（不关，随时叫回）
        for w in wins where !used.contains(w.id) && !w.isMinimized {
            guard let last = lastFocused(w), last > .distantPast else { continue }
            let days = now.timeIntervalSince(last) / 86400
            guard days >= staleDays else { continue }
            out.append(TidyItem(kind: .stale, action: .stash, windowID: w.id, pid: w.pid, bundleID: w.bundleID,
                                appName: w.appName, title: w.title,
                                reason: "\(Int(days)) 天没用过", checked: !messaging.contains(w.bundleID)))
            used.insert(w.id)
        }

        // 4) 开着却没有窗口的 App
        let withWindows = Set(windows.map(\.pid))
        for a in apps where !a.isActive && !withWindows.contains(a.pid) && !neverQuit.contains(a.bundleID) {
            let chat = messaging.contains(a.bundleID)
            out.append(TidyItem(kind: .idleApp, action: .quit, windowID: nil, pid: a.pid, bundleID: a.bundleID,
                                appName: a.name, title: a.name,
                                reason: chat ? "没有打开的窗口（退出后收不到消息）" : "没有打开的窗口，还在占内存",
                                checked: !chat))
        }
        return out
    }
}
