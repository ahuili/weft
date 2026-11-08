import Foundation

/// 极简 OpenAI Chat Completions 客户端（支持 tools）。消息用字典表示，方便原样回传 tool_calls。
public final class ChatClient {
    public let config: AIConfig
    public init(config: AIConfig) { self.config = config }

    public struct ToolCall {
        public var id: String
        public var name: String
        public var arguments: String
    }

    public struct Reply {
        public var content: String?
        public var toolCalls: [ToolCall]
        /// 原始 assistant 消息，追加回对话历史
        public var rawMessage: [String: Any]
    }

    public func complete(messages: [[String: Any]], tools: [[String: Any]], toolChoice: Any = "auto", timeout: TimeInterval = 90) async throws -> Reply {
        guard config.isConfigured else { throw AIError.notConfigured }
        guard let url = URL(string: config.baseURL.trimmingSlash + "/chat/completions") else { throw AIError.badURL }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let k = config.apiKey, !k.isEmpty { req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = ["model": config.model, "messages": messages, "temperature": 0.2]
        if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = toolChoice }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try AIError.check(resp, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first,
              let msg = choice["message"] as? [String: Any]
        else { throw AIError.badResponse(String(data: data, encoding: .utf8)?.prefix(200).description ?? "") }

        let calls: [ToolCall] = (msg["tool_calls"] as? [[String: Any]] ?? []).compactMap { c in
            guard let id = c["id"] as? String, let f = c["function"] as? [String: Any],
                  let name = f["name"] as? String else { return nil }
            let args = (f["arguments"] as? String) ?? "{}"
            return ToolCall(id: id, name: name, arguments: args)
        }
        // 回传给模型时只保留协议字段（去掉 reasoning_content 等扩展字段）
        var raw: [String: Any] = ["role": "assistant", "content": msg["content"] as? String ?? ""]
        if let tc = msg["tool_calls"] { raw["tool_calls"] = tc }
        return Reply(content: msg["content"] as? String, toolCalls: calls, rawMessage: raw)
    }
}
