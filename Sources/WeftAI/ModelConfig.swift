import Foundation
import Security
import WeftCore

/// 模型服务商预设。都走 OpenAI 兼容协议（/chat/completions + /models）。
public struct AIProvider: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var needsKey: Bool
    /// 申请 API Key 的地址
    public var keyURL: String?
    /// /models 拉不到时给的候选
    public var suggested: [String]
    public var note: String

    public static let magpie = AIProvider(id: "magpie", name: "Magpie（本机）", baseURL: "http://127.0.0.1:3425/v1", needsKey: false,
                                          keyURL: nil, suggested: [], note: "从本机已安装的 Magpie 导入模型，无需 Key")
    public static let custom = AIProvider(id: "custom", name: "自定义（OpenAI 兼容）", baseURL: "", needsKey: true,
                                          keyURL: nil, suggested: [], note: "任何兼容 OpenAI 接口的服务，填 base URL（通常以 /v1 结尾）")

    public static let all: [AIProvider] = [
        .magpie,
        AIProvider(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", needsKey: true,
                   keyURL: "https://platform.deepseek.com/api_keys", suggested: ["deepseek-chat", "deepseek-reasoner"], note: "便宜、中文好，推荐"),
        AIProvider(id: "qwen", name: "通义千问（阿里云百炼）", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", needsKey: true,
                   keyURL: "https://bailian.console.aliyun.com/?apiKey=1", suggested: ["qwen-plus", "qwen-turbo", "qwen-max"], note: ""),
        AIProvider(id: "kimi", name: "Kimi（月之暗面）", baseURL: "https://api.moonshot.cn/v1", needsKey: true,
                   keyURL: "https://platform.moonshot.cn/console/api-keys", suggested: ["kimi-latest", "moonshot-v1-8k"], note: ""),
        AIProvider(id: "zhipu", name: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4", needsKey: true,
                   keyURL: "https://open.bigmodel.cn/usercenter/apikeys", suggested: ["glm-4-flash", "glm-4-plus"], note: "glm-4-flash 免费"),
        AIProvider(id: "doubao", name: "豆包（火山方舟）", baseURL: "https://ark.cn-beijing.volces.com/api/v3", needsKey: true,
                   keyURL: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey", suggested: [], note: "模型名填方舟里的推理接入点 ID"),
        AIProvider(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", needsKey: true,
                   keyURL: "https://platform.openai.com/api-keys", suggested: ["gpt-4o-mini", "gpt-4.1-mini"], note: ""),
        AIProvider(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", needsKey: true,
                   keyURL: "https://openrouter.ai/keys", suggested: [], note: "一个 Key 用各家模型"),
        AIProvider(id: "ollama", name: "Ollama（本机）", baseURL: "http://127.0.0.1:11434/v1", needsKey: false,
                   keyURL: nil, suggested: ["qwen2.5:7b", "llama3.1:8b"], note: "完全离线；小模型分组效果一般"),
        .custom,
    ]

    public static func find(_ id: String?) -> AIProvider? { all.first { $0.id == id } }
}

/// AI 设置。没配置过时 provider 为 nil，AI 功能会引导用户先去选模型。
/// API Key 存在钥匙串里，不落盘到 ai.json。
public struct AIConfig: Codable, Equatable {
    public var provider: String?
    /// OpenAI 兼容的 base URL（包含 /v1）
    public var baseURL: String
    public var model: String
    /// 这些 App 的窗口标题不会发给模型（只发 App 名）
    public var redactTitlesFor: [String]
    /// 只在内存里；load() 时从钥匙串读
    public var apiKey: String?

    enum CodingKeys: String, CodingKey { case provider, baseURL, model, redactTitlesFor }

    public init(provider: String?, baseURL: String, apiKey: String? = nil, model: String,
                redactTitlesFor: [String] = AIConfig.defaultRedact) {
        self.provider = provider; self.baseURL = baseURL; self.apiKey = apiKey
        self.model = model; self.redactTitlesFor = redactTitlesFor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        baseURL = (try c.decodeIfPresent(String.self, forKey: .baseURL)) ?? ""
        model = (try c.decodeIfPresent(String.self, forKey: .model)) ?? ""
        redactTitlesFor = (try c.decodeIfPresent([String].self, forKey: .redactTitlesFor)) ?? AIConfig.defaultRedact
    }

    public var isConfigured: Bool { provider != nil && !baseURL.isEmpty && !model.isEmpty }

    public var providerName: String { AIProvider.find(provider)?.name ?? "未配置" }

    public static let defaultRedact = ["com.tencent.xinWeChat", "com.tencent.qq", "ru.keepcoder.Telegram",
                                       "com.apple.MobileSMS", "com.electron.lark", "com.bytedance.lark"]

    public static let magpieBaseURL = AIProvider.magpie.baseURL

    public static var unconfigured: AIConfig { AIConfig(provider: nil, baseURL: "", model: "") }

    public static func load(_ store: Store = .shared) -> AIConfig {
        var c = store.load(AIConfig.self, "ai.json") ?? .unconfigured
        if let p = c.provider { c.apiKey = Keychain.get(p) }
        return c
    }

    public func save(_ store: Store = .shared) {
        store.save(self, "ai.json")
        if let p = provider {
            if let k = apiKey, !k.isEmpty { Keychain.set(p, k) } else { Keychain.delete(p) }
        }
    }
}

/// 极简钥匙串封装（通用密码，service = local.weft.ai）
public enum Keychain {
    static let service = "local.weft.ai"

    public static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func set(_ account: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        let data = Data(value.utf8)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

public struct ModelEntry: Equatable, Identifiable {
    public var id: String
    public var label: String
    public var supportsTools: Bool
    public init(id: String, label: String, supportsTools: Bool) { self.id = id; self.label = label; self.supportsTools = supportsTools }
}

/// 读取模型列表（GET /models）：Magpie 和大多数 OpenAI 兼容服务都支持
public enum ModelDiscovery {
    public static func listModels(baseURL: String, apiKey: String? = nil, timeout: TimeInterval = 4) async throws -> [ModelEntry] {
        guard let url = URL(string: baseURL.trimmingSlash + "/models") else { throw AIError.badURL }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        if let k = apiKey, !k.isEmpty { req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        try AIError.check(resp, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else { throw AIError.badResponse("models") }
        return arr.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let label = (m["magpie_label"] as? String) ?? (m["display_name"] as? String) ?? id
            let params = m["supported_parameters"] as? [String]
            // 没有能力字段的服务默认当作支持工具调用
            let tools = (m["tool_call"] as? Bool) ?? params.map { $0.contains("tools") } ?? true
            return ModelEntry(id: id, label: label, supportsTools: tools)
        }
    }

    /// Magpie 是否在本机运行
    public static func magpieAvailable() async -> Bool {
        (try? await listModels(baseURL: AIConfig.magpieBaseURL, timeout: 1).isEmpty == false) ?? false
    }

    /// 发一句最小请求，确认 Key / 模型可用。返回耗时（秒）
    public static func ping(_ config: AIConfig) async throws -> Double {
        let t = Date()
        let client = ChatClient(config: config)
        _ = try await client.complete(messages: [["role": "user", "content": "回复 ok"]], tools: [], timeout: 30)
        return Date().timeIntervalSince(t)
    }
}

public enum AIError: Error, CustomStringConvertible {
    case badURL
    case http(Int, String)
    case badResponse(String)
    case notConfigured

    public var description: String {
        switch self {
        case .badURL: return "模型地址无效"
        case .http(401, _), .http(403, _): return "API Key 无效或没有权限"
        case .http(let c, let b): return "HTTP \(c)：\(b.prefix(300))"
        case .badResponse(let s): return "无法解析模型返回（\(s)）"
        case .notConfigured: return "还没有选择 AI 模型"
        }
    }

    static func check(_ resp: URLResponse, _ data: Data) throws {
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw AIError.http(h.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

extension String {
    var trimmingSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}
