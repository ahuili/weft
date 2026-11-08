import Foundation
import WeftCore

/// AI 复盘：把本机统计（几点用什么、常怎么摆）写成几句简短的「记忆笔记」
public final class MemoryAdvisor {
    public let client: ChatClient
    public init(config: AIConfig) { client = ChatClient(config: config) }

    static let tool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "write_memory",
            "description": "写下关于用户工作习惯的记忆笔记",
            "parameters": [
                "type": "object",
                "properties": [
                    "notes": ["type": "array", "items": ["type": "string"],
                              "description": "3~8 条，每条 30 字以内的中文短句，具体到 App / 时间 / 摆法"],
                ],
                "required": ["notes"],
            ],
        ],
    ]

    static let systemPrompt = """
    你是 Weft 的习惯记忆整理员。下面是用户在 Mac 上的窗口使用统计（全部在本机统计，只有 App 名和标题）。
    请写 3~8 条「记忆笔记」，以后整理窗口、推荐摆法时会参考它们。要求：
    - 只写从数据里看得出来、稳定的习惯，比如「早上 9~11 点主要在钉钉和邮件」「写 Weft 时 VS Code 和 Ghostty 并排」「微信总在笔记本屏上」。
    - 具体：说出 App、时段、怎么摆。不要空话（如「用户很忙」），不要建议，不要猜测隐私。
    - user_notes 是用户自己写的，不要重复，也不要和它矛盾。
    - 必须调用 write_memory。
    """

    public func digest(stats: [String: Any], userNotes: [String]) async throws -> [String] {
        var payload = stats
        payload["user_notes"] = userNotes
        let json = String(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
        let reply = try await client.complete(
            messages: [["role": "system", "content": Self.systemPrompt], ["role": "user", "content": json]],
            tools: [Self.tool], toolChoice: ["type": "function", "function": ["name": "write_memory"]], timeout: 120)
        var text = reply.toolCalls.first(where: { $0.name == "write_memory" })?.arguments
        if text == nil, let c = reply.content, let r = c.range(of: #"\{[\s\S]*\}"#, options: .regularExpression) { text = String(c[r]) }
        guard let text, let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw AIError.badResponse("write_memory")
        }
        return Self.clean(obj["notes"] as? [Any] ?? [])
    }

    static func clean(_ arr: [Any]) -> [String] {
        var seen = Set<String>()
        return arr.compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 80 && seen.insert($0).inserted }
            .prefix(8).map { $0 }
    }
}
