import Foundation
import WeftCore

/// AI 整理：在规则之外，判断哪些窗口「事情已经办完了」可以关、哪些该收起来
public final class TidyAdvisor {
    public let client: ChatClient
    public init(config: AIConfig) { client = ChatClient(config: config) }

    static let tool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "propose_tidy",
            "description": "给出整理建议",
            "parameters": [
                "type": "object",
                "properties": [
                    "summary": ["type": "string", "description": "一句话总结现在桌面的状况，20 字以内"],
                    "items": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "window_id": ["type": "integer"],
                                "action": ["type": "string", "enum": ["close", "stash", "minimize", "keep"]],
                                "reason": ["type": "string", "description": "12 字以内，如「搜索结果，已经查完」"],
                            ],
                            "required": ["window_id", "action", "reason"],
                        ],
                    ],
                ],
                "required": ["items"],
            ],
        ],
    ]

    static let systemPrompt = """
    你是 Weft 的桌面整理助手。用户的 Mac 上开了太多窗口，请逐个判断：
    - close：内容是一次性的、事情大概率已经办完（搜索结果页、已读完的文章、登录 / 跳转 / 支付完成页、下载完成页、重复打开的同一文档、报错页）
    - stash：暂时不用但之后可能还要（参考资料、进行中但今天不碰的项目），收进后台不关闭
    - minimize：很少用，但用户可能想在 Dock 里看到
    - keep：正在做的事、最近用过的、编辑器 / 终端里未完成的工作、聊天主窗口
    规则：
    - focused 和 recent 前 5 个一律 keep；last_used_days 越大越可能 close/stash；minutes 是累计使用分钟，越多越重要。
    - 编辑器、终端、文档类不要 close（可能有未保存内容），最多 stash。
    - 拿不准就 keep。只返回不是 keep 的窗口。
    - user_memory 是用户的习惯记忆，参考它判断哪些窗口是常用的。
    - 必须调用 propose_tidy。
    """

    public struct Advice {
        public var summary: String
        public var items: [TidyItem]
    }

    public func advise(windows: [WindowInfo], focused: UInt32?, recent: [UInt32],
                       lastUsedDays: [UInt32: Double], minutes: [UInt32: Double], redact: Set<String>, memory: [String] = []) async throws -> Advice {
        let wins = windows.map { w -> [String: Any] in
            var o: [String: Any] = ["id": Int(w.id), "app": w.appName,
                                    "title": redact.contains(w.bundleID) ? "(隐藏)" : String(w.title.prefix(100))]
            if let d = lastUsedDays[w.id] { o["last_used_days"] = (d * 10).rounded() / 10 }
            if let m = minutes[w.id], m > 0 { o["minutes"] = Int(m) }
            if w.isMinimized { o["minimized"] = true }
            return o
        }
        let payload: [String: Any] = ["windows": wins, "focused": focused.map { Int($0) } as Any,
                                      "recent": recent.prefix(10).map { Int($0) }, "user_memory": memory]
        let json = String(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
        let reply = try await client.complete(
            messages: [["role": "system", "content": Self.systemPrompt], ["role": "user", "content": json]],
            tools: [Self.tool], toolChoice: ["type": "function", "function": ["name": "propose_tidy"]], timeout: 180)
        var text = reply.toolCalls.first(where: { $0.name == "propose_tidy" })?.arguments
        if text == nil, let c = reply.content, let r = c.range(of: #"\{[\s\S]*\}"#, options: .regularExpression) { text = String(c[r]) }
        guard let text, let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { throw AIError.badResponse("propose_tidy") }
        let protected = Set([focused].compactMap { $0 } + recent.prefix(5))
        return Advice(summary: (obj["summary"] as? String) ?? "",
                      items: Self.parse(obj["items"] as? [[String: Any]] ?? [], windows: windows, protected: protected))
    }

    /// 校验：去掉不存在的窗口、keep、正在用的窗口；编辑器 / 终端的 close 降级为 stash
    public static func parse(_ arr: [[String: Any]], windows: [WindowInfo], protected: Set<UInt32>) -> [TidyItem] {
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let careful: Set<String> = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.apple.Terminal", "com.googlecode.iterm2",
                                    "com.mitchellh.ghostty", "org.tabby", "com.jetbrains.intellij", "com.apple.TextEdit",
                                    "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.apple.iWork.Pages",
                                    "md.obsidian", "notion.id", "com.exafunction.windsurf", "com.trae.app"]
        var seen = Set<UInt32>()
        return arr.compactMap { o in
            let id = (o["window_id"] as? Int).map(UInt32.init) ?? (o["window_id"] as? String).flatMap { UInt32($0) }
            guard let id, let w = byID[id], !protected.contains(id), !seen.contains(id),
                  let raw = o["action"] as? String, raw != "keep", var action = TidyAction(rawValue: raw) else { return nil }
            seen.insert(id)
            if action == .close && careful.contains(w.bundleID) { action = .stash }
            return TidyItem(kind: .ai, action: action, windowID: id, pid: w.pid, bundleID: w.bundleID, appName: w.appName,
                            title: w.title, reason: (o["reason"] as? String) ?? "", checked: action != .close)
        }
    }
}
